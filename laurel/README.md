# LAUREL

[LAUREL](https://github.com/threathunters-io/laurel) transforms auditd's raw
records into enriched JSON that the Wazuh agent can forward. `install-laurel.sh`
in this directory is what both `install.sh` and the Ansible role call.

See [../README.md](../README.md) for the installer itself.

---

## How LAUREL gets installed, and pinning its version

On **x86_64** the installer downloads upstream's `x86_64-musl` release tarball and verifies it against a sha256 pinned in `laurel/install-laurel.sh`. That binary is `static-pie` linked with no `NEEDED` entries at all — no libc, no `libacl` — so one artefact runs on every distribution the installer supports, and no Rust toolchain, `clang` or `-dev` package is installed on the host.

On **other architectures** it builds from source as before. Upstream publishes no static asset for aarch64 or armv7, and its glibc builds are not a portable substitute: v0.8.2's require `GLIBC_2.30`, which is newer than RHEL 8 (2.28) or Debian 10 ship, despite what upstream's `INSTALL.md` says about CentOS 7.

The version is pinned, because the checksum is: a version and its hash are bumped together. To install a different release, supply both:

```bash
sudo LAUREL_VERSION=v0.8.3 \
     LAUREL_SHA256=<sha256 of laurel-0.8.3-x86_64-musl.tar.gz> \
     bash install.sh --manager 10.0.0.1
```

Pass `LAUREL_VERSION` alone and the installer builds that tag from source instead of installing a tarball it cannot verify. Upstream ships no checksum or signature files alongside its releases, so this pin is the only thing standing between a release asset and `/usr/local/sbin`. A hash mismatch aborts the install; a failed *download* falls back to a source build.

**The one regression to know about.** A static musl binary cannot use `nsswitch`, so user and group lookups read `/etc/passwd` and `/etc/group` only ([upstream issue #84](https://github.com/threathunters-io/laurel/issues/84)). On a host whose users come from SSSD, LDAP, winbind or NIS, the `enrich.user-groups` output is incomplete — the installer checks `/etc/nsswitch.conf` and warns when it sees this. UID→name translation is unaffected, since `translate.user-db` is off in the shipped config. For a build that can query `nsswitch`:

```bash
sudo LAUREL_BUILD_FROM_SOURCE=1 bash install.sh --manager 10.0.0.1
```

The source build installs a Rust toolchain via `rustup` when `cargo` is absent. On hosts where neither path is acceptable, use `--skip-laurel`.

## SELinux

Upstream's release tarballs ship no SELinux policy. Without one, on an SELinux host (Fedora, RHEL and its rebuilds), auditd starts LAUREL inside its own `auditd_t` domain. There LAUREL's `chown` of `/var/log/laurel` is denied, so it crash-loops (`chown: /var/log/laurel: EACCES` in `journalctl -u auditd`) until auditd gives up.

When `selinuxenabled` succeeds, the installer:

1. installs `selinux-policy-devel`;
2. downloads upstream's `contrib/selinux` files (`laurel.te`, `laurel.fc`, `Makefile`) from the pinned tag and checks them against the sha256 values in `install-laurel.sh`;
3. builds the module on the host and loads it with `semodule -i`. On Fedora 42+ `/usr/local/sbin` is a symlink to `bin`, so the real path `/usr/local/bin/laurel` is added to `laurel.fc`, since upstream doesn't list it;
4. relabels the binary, config, log directory and plugin config with `restorecon`.

Upstream's policy runs LAUREL in its own `laurel_t` domain, which it marks permissive. Re-running the installer on a host where LAUREL is already installed applies the module and reloads auditd, so a re-run also fixes hosts installed before this step existed. `--uninstall` removes the module.


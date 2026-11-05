# Testing

How to verify an installed host, the Wazuh rules behind it, and `install.sh` itself.
See [README.md](README.md) for installation and configuration, and
[ansible/TESTING.md](ansible/TESTING.md) for testing the Ansible role.

## Testing the rules

Run both on the monitored host after installation. Each triggers every rule category and confirms the expected event was recorded.

```bash
sudo bash auditd/test/audit-test.sh --verbose
sudo bash falco/test/falco-test.sh --verbose
```

Run them from a terminal: several rules filter on a TTY being attached, and those checks skip with a note over a non-interactive SSH command.

Neither script leaves changes behind. In the auditd script, existing files are poked with `touch -r FILE FILE` (fires the attribute watch, mtime unchanged, no FIM alert) and temporary files are removed on exit. The Falco script connects only to a throwaway listener on `127.0.0.2`, checks the sensor-stop rule with `systemctl --dry-run stop` (which produces the command line the rule matches without touching the unit) and then asserts Falco is still running, and never writes to an existing `ld.so.preload` or history file. A missing path or binary is reported as `SKIP` rather than aborting the run.

Expected on a current Ubuntu or Debian host: all Falco checks pass, and the auditd script skips four checks — `exec` and `exec_root_unattributed` (disabled by design), `remote_shell` (needs a reachable listener) and `interpreter` (the symlink limitation above).

### Verifying the Wazuh rules against real events

The sensor firing is only half of it; the manager has to map it to the rule you intended. Take a real line from either sensor and run it through `wazuh-logtest` on the manager, with `-l` set to the location the rule matches on:

```bash
tail -1 /var/log/falco/events.json  | /var/ossec/bin/wazuh-logtest -l /var/log/falco/events.json
tail -1 /var/log/laurel/audit.log   | /var/ossec/bin/wazuh-logtest -l /var/log/laurel/audit.log
```

Without `-l`, the location is `stdin`, the base rules `225100` and `223100` do not match, and nothing fires even though the ruleset is correct. Note also that `wazuh-logtest` writes its phase output to **stderr**, so redirect `2>&1` if you are parsing it.

### Testing the installer across distributions

The two scripts above test the *rules*, on a host that is already installed. To test `install.sh` itself on a distribution you do not have a VM for, `test/container-test.sh` builds a minimal systemd container per target and runs the installer and uninstaller inside it:

```bash
bash test/container-test.sh                              # debian:12 debian:13 ubuntu:24.04 almalinux:9
bash test/container-test.sh --target debian:13 --verbose
```

It needs docker and cgroup v2, and does not need root. The manager address defaults to `192.0.2.1`, which is TEST-NET-1 and unroutable on purpose: the agent installs and starts without enrolling, so running the harness cannot leave stray agents in a real manager's agent list.

It covers repo and GPG key setup, package availability and naming, the non-interactive Falco driver preseed, unit names, ruleset/config/logrotate deployment, `falco --validate`, the `<localfile>` blocks, and the whole uninstall and purge path including that `/var/log/falco` survives.

`test/laurel-prebuilt-test.sh` covers the LAUREL install-path decision separately — which hosts get the prebuilt binary and which build from source — and with `--online` re-checks the pinned sha256 against the asset upstream currently serves, which is the check to run after bumping `LAUREL_VERSION`:

```bash
bash test/laurel-prebuilt-test.sh            # decision logic only, no network
bash test/laurel-prebuilt-test.sh --online   # also verify the pin
```

It does **not** cover anything kernel-coupled, because a container shares the host kernel: auditd rules actually loading, the Falco driver attaching, or any event firing. The driver choice is even made from the *host's* kernel version and BTF rather than the target distribution's. auditd and LAUREL are skipped for that reason, and both sensor test scripts still need a real VM of the target distribution.

> **Never add `--privileged` to this harness.** The kernel audit subsystem is not namespaced — there is one audit netlink socket per kernel, shared with the host. A privileged container has `CAP_AUDIT_CONTROL`, so `augenrules --load` inside it does not configure the container, it replaces the audit rules of the machine you are sitting at, and `auditctl -e 2` would lock them until that machine reboots. The harness runs unprivileged (`--cap-add SYS_ADMIN` is enough for systemd as PID 1) and asserts that `CAP_AUDIT_CONTROL` is dropped before it will run the installer at all.

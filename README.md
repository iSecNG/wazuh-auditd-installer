# wazuh-auditd-installer

Linux installer that deploys a [Wazuh](https://wazuh.com/) agent with two complementary sensors: auditd with [LAUREL](https://github.com/threathunters-io/laurel) for the audit trail, and [Falco](https://falco.org/) for behavioural detection. Supports Ubuntu/Debian, RHEL/CentOS/AlmaLinux/Rocky, Fedora, Amazon Linux, and openSUSE/SLES.

## Quick start

```bash
sudo bash install.sh --manager <manager-ip-or-fqdn>
```

This installs:
1. The **Wazuh agent** (configured and enrolled against your manager)
2. **auditd** with the hardened ruleset from this repo, as `/etc/audit/rules.d/99-wazuh.rules`
3. **LAUREL** (built from its latest release tag, registered as an auditd plugin)
4. **Falco** (from the official package repo, `modern_ebpf` driver) with this repo's ruleset in `/etc/falco/rules.d/`
5. A `<localfile>` entry in `ossec.conf` for each sensor, so the agent forwards `/var/log/laurel/audit.log` and `/var/log/falco/events.json`

Exit status is `0` only if the agent, auditd, LAUREL and Falco are all running afterwards.

## Sensor division of labour

Each sensor does the job it is good at, and each detection alerts exactly once.

| | auditd + LAUREL | Falco |
|---|---|---|
| **Role** | audit trail and compliance record | behavioural detection |
| **Covers** | authentication and login events, account and group changes, sudoers and PAM, persistence-relevant file changes, time changes, its own integrity | reverse shells, execution from world-writable paths, credential reads, privilege-escalation shapes, setuid backdoors, anti-forensics, sensor tampering |
| **Sees what the other cannot** | PAM/`USER_AUTH` records and other events that never pass through a syscall; delivery guarantees under load (`-f 2`) | parent process, full command line, cwd and socket peer on a single event |
| **Wazuh rules** | `223000-det-laurel-generic.xml` | `225000-det-falco-generic.xml` |

Where both sensors see the same action, auditd keeps collecting it but its Wazuh rule sits at **level 3** as the forensic trail, and Falco raises the alert. That is what keeps one action from producing two alerts.

Falco also watches auditd's configuration while auditd watches Falco's (keys `falco_config`, `falco_exec`, `falco_logs`, `laurel_config`, `bpf_load`), so neither sensor can be silenced without the other recording it.

## All options

```
sudo bash install.sh --manager <addr> [OPTIONS]
sudo bash install.sh --uninstall [OPTIONS]

Required (install only):
  --manager <addr>                    Wazuh manager IP or FQDN

Wazuh agent deployment variables:
  --manager-port <port>               Manager connection port
  --protocol <tcp|udp>                Communication protocol (default: TCP)
  --registration-server <addr>        Enrollment server (default: --manager)
  --registration-port <port>          Enrollment server port
  --registration-password <pass>      Enrollment password (prefer the env var)
  --keep-alive-interval <secs>        Agent keep-alive interval
  --time-reconnect <secs>             Reconnection interval
  --registration-ca <path>            CA certificate path for SSL enrollment
  --registration-certificate <path>   Agent certificate path for SSL enrollment
  --registration-key <path>           Agent key path for SSL enrollment
  --agent-name <name>                 Agent name (default: hostname)
  --agent-group <groups>              Comma-separated group list
  --enrollment-delay <secs>           Post-enrollment delay

Install options:
  --wazuh-version <version>           Pin Wazuh version, e.g. 4.9.1 (default: latest)
  --package-path <path>               Install from local .deb/.rpm (offline/air-gapped)
  --skip-auditd                       Skip auditd + ruleset deployment
  --skip-laurel                       Skip LAUREL installation
  --skip-falco                        Skip Falco installation
  --dry-run                           Print actions without making changes
  --verbose                           Echo each command before running it
  -h, --help                          Show full help

Uninstall options:
  --uninstall                         Remove Wazuh agent, auditd rules, LAUREL and Falco
  --skip-auditd                       Skip auditd rules removal
  --skip-laurel                       Skip LAUREL removal
  --skip-falco                        Skip Falco removal
  --dry-run                           Preview what would be removed
```

All `--flags` can also be set as environment variables (e.g. `WAZUH_MANAGER=10.0.0.1`). CLI flags take precedence.

Pass the enrollment password through the environment rather than the command line — an argument is visible in `ps` to every local user:

```bash
sudo WAZUH_REGISTRATION_PASSWORD="$(cat /root/.wazuh-pass)" bash install.sh --manager 10.0.0.1
```

### Re-running on a host that already has the agent

The `WAZUH_*` deployment variables are applied by the Wazuh package's post-install script. If `wazuh-agent` is already installed, that script does not run again, so a different `--manager` or `--agent-group` has no effect — the installer says so instead of reporting success. Edit `/var/ossec/etc/ossec.conf`, or purge the agent first.

### Pinning the LAUREL version

By default the newest release tag on the LAUREL remote is built. To pin one:

```bash
sudo LAUREL_VERSION=v0.8.2 bash install.sh --manager 10.0.0.1
```

LAUREL is compiled from source, which installs a Rust toolchain via `rustup` when `cargo` is absent. On hosts where that is not acceptable, use `--skip-laurel` and deploy a pre-built binary.

### Falco driver and kernel requirements

Falco is installed from the official package repository. The installer selects the driver itself:

- **`modern_ebpf`** when the kernel is 5.8 or newer and `/sys/kernel/btf/vmlinux` exists. This is CO-RE: the probe is embedded in the Falco binary, so no compiler and no kernel headers are needed on the host, and a kernel upgrade changes nothing.
- **`kmod`** otherwise, which DKMS-compiles a kernel module at install time and again on every kernel update. It needs a compiler and the matching kernel headers. The installer warns when it falls back, since this is often not acceptable on a production host; use `--skip-falco` in that case.

The installer passes `FALCO_DRIVER_CHOICE`, `FALCOCTL_ENABLED=no` and `FALCO_FRONTEND=noninteractive` to the package, so it never prompts and the driver choice is reproducible rather than auto-detected per host.

`FALCOCTL_ENABLED=no` makes the package mask `falcoctl-artifact-follow.service`, which would otherwise replace `falco_rules.yaml` on its own schedule. The ruleset therefore stays pinned to whatever the installed package shipped, and detections do not change between hosts or without a deployment. To opt back in:

```bash
sudo systemctl unmask --now falcoctl-artifact-follow.service
```

Falco's upstream ruleset (`falco_rules.yaml`, around 90 rules) stays loaded alongside this repo's. See the tuning notes below for how the two interact.

## Manager-side setup

Deploy the Wazuh rules to your **Wazuh manager**, with the ownership the manager expects:

```bash
install -o wazuh -g wazuh -m 0660 wazuh/rules/223000-det-laurel-generic.xml   /var/ossec/etc/rules/
install -o wazuh -g wazuh -m 0660 wazuh/rules/224000-excl-laurel-generic.xml  /var/ossec/etc/rules/
install -o wazuh -g wazuh -m 0660 wazuh/rules/225000-det-falco-generic.xml    /var/ossec/etc/rules/
install -o wazuh -g wazuh -m 0660 wazuh/rules/226000-excl-falco-generic.xml   /var/ossec/etc/rules/
/var/ossec/bin/wazuh-analysisd -t    # verify the ruleset loads before restarting
systemctl restart wazuh-manager
```

`wazuh-analysisd -t` exits non-zero and names the file if any rule fails to parse or references a parent that is not loaded. Run it before every restart.

Keep the numeric filename prefixes. The manager loads `etc/rules/` in filename order, and each exclusion file references detection rules in the preceding file as parents via `<if_sid>`, which must already be loaded:

| File | Range | Contents |
|---|---|---|
| `223000-det-laurel-generic.xml` | 223100-223399 | auditd/LAUREL detections |
| `224000-excl-laurel-generic.xml` | 224000-224099 | auditd/LAUREL exclusions |
| `225000-det-falco-generic.xml` | 225100-225399 | Falco detections |
| `226000-excl-falco-generic.xml` | 226000-226099 | Falco exclusions |

A rule change on the manager is not picked up until `wazuh-manager` restarts: `analysisd` holds the ruleset in memory, so `wazuh-logtest` keeps reporting the old rules until then.

Then confirm the field paths against a real event, by pasting one line of `/var/log/laurel/audit.log` into `wazuh-logtest`:

```bash
/var/ossec/bin/wazuh-logtest
```

The LAUREL rules assume `SYSCALL.key` is emitted as a plain string and that `SYSCALL.exe` and `SYSCALL.comm` exist. The Falco rules match on the top-level `rule` and `priority` fields, with per-field values available as `output_fields.<falco field>` (for example `output_fields.proc.pname`). If your versions differ, adjust the anchored regexes in the corresponding detection file.

Falco rule names are an API contract between `falco/rules/wazuh-falco-rules.yaml` and `225000-det-falco-generic.xml`. Renaming a rule in the ruleset without updating its Wazuh rule silently drops it to the generic priority rules, so it still alerts, but at the generic level and without its MITRE mapping.

### Collecting the sensor logs through centralized configuration

LAUREL logs JSON to `/var/log/laurel/audit.log` and Falco to `/var/log/falco/events.json`. To collect them centrally, add this to `/var/ossec/etc/shared/<group>/agent.conf` and remove the installer's blocks from each agent's `ossec.conf`:

```xml
<agent_config>
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/laurel/audit.log</location>
  </localfile>
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/falco/events.json</location>
  </localfile>
</agent_config>
```

## What the rules cover

**auditd + LAUREL** (`auditd/rules/audit.rules`, `223000-det-laurel-generic.xml`): login and authentication events, account and group management, sudoers and PAM, SSH configuration and root keys, service/cron/kernel-module persistence, credential and SSL key file access, network and firewall changes, time manipulation, DAC permission changes, mount and kexec, Wazuh agent integrity, the audit subsystem's own integrity, and Falco's integrity. Syscall rules are duplicated for `b32` so a 32-bit process on a 64-bit host cannot bypass them.

**Falco** (`falco/rules/wazuh-falco-rules.yaml`, `225000-det-falco-generic.xml`): reverse shells (both the `/dev/tcp` and the `dup`-onto-stdio shapes), execution from world-writable directories, shells spawned below non-shell applications, polkit privilege escalation, `ld.so.preload` modification, setuid/setgid backdoors, SSH private key reads, eBPF program loading, shell history tampering, tunnelling tools, and sensor tampering. The interactive-command, reconnaissance and data-transfer rules carry the per-command trail that auditd's broad `execve` rule used to provide.

MITRE ATT&CK technique IDs are mapped throughout both rulesets.

### Broad execve collection is disabled by default

`auditd/rules/audit.rules` ships with the broad `-S execve -F auid>=1000 -k exec` rules commented out, for two reasons.

The kernel evaluates audit rules first-match-wins. Those rules sit ahead of every `-p x` watch in the file and match any `execve`, so they tagged all those events `key=exec` and the specific keys — `priv_esc`, `audittools`, `user_mgmt`, `firewall`, `network_tools`, `exfil_tools`, `recon`, `interpreter`, `power`, `wazuh_exec` — were never set at all. Every Wazuh rule written against those keys was dead, which is why they used to match on `SYSCALL.exe` instead. With the broad rules disabled, the keys fire and the per-category forensic trail works.

Falco also reports the same executions with the parent process and full command line on one event, which auditd does not expose as queryable fields.

Re-enable them only if a compliance framework explicitly requires a complete command trail from the audit subsystem — auditd can guarantee delivery under load with `-f 2`, whereas Falco drops events under pressure. If you do, the per-tool keys go quiet again and their Wazuh rules should be demoted or removed. The block in section 4 of the ruleset explains this inline.

### Tuning before production

Levels and the `frequency`/`timeframe` values in both detection files are starting points, not measurements:

- Rule `225150` alerts at level 3 on **every** interactive command (anything with a TTY attached). It dominates alert volume; that is the intent, but size your indexer for it.
- The composite rules `223350`–`223353` and `225300`–`225302` fire on bursts. Baseline them against your own hosts first: a configuration-management run or an admin troubleshooting session legitimately produces bursts.
- Rule order inside each detection file is load-bearing. `analysisd` keeps the first matching child of a parent rule, so the generic priority rules `225380`–`225382` sit at the end of `225000-det-falco-generic.xml` on purpose. Moving them up disables every specific Falco rule above them.
- Order is load-bearing inside the Falco ruleset too. Falco's `rule_matching` is `first`, so `"Wazuh: Interactive command executed on terminal"` is defined last: it matches any command with a TTY and would otherwise swallow the reconnaissance and data-transfer rules, silently breaking the burst rules that count them.
- **Upstream Falco rules win over this repo's.** `falco_rules.yaml` is loaded before `/etc/falco/rules.d`, and that order cannot be changed from a config drop-in. Two upstream rules therefore cover ground this repo would otherwise duplicate, and are mapped by name instead: `Read sensitive file untrusted` (rule `225140`) and `Run shell untrusted` (rule `225141`). Before adding a Falco rule, trigger it on a test host and confirm your rule name — not an upstream one — appears in `/var/log/falco/events.json`.
- Upstream's remaining rules land on the generic priority rules `225380`–`225382` (Notice → 3, Warning/Error → 8, Critical+ → 12). Run them for a while, find which ones matter in your environment, then give those their own rule in the `225200`–`225299` band with a proper level and MITRE ID.
- The exclusion files hold the whitelists: `224000-excl-laurel-generic.xml` for Wazuh's own agent processes and the netplan generator, `226000-excl-falco-generic.xml` for the SCA module's credential-file reads plus disabled templates for configuration-management and package-manager noise. Add your own environment's noise there rather than editing the detection files, so the two stay separable on update.
- For recurring host noise, prefer filtering in Falco over an exclusion in Wazuh: a rule that never fires costs nothing, while an excluded event has already crossed the agent and `analysisd`. The ruleset exposes a `wz_user_known_activity` macro for this. Redefine it in a file that sorts after the shipped ruleset, for example `/etc/falco/rules.d/zz-local-tuning.yaml`:

  ```yaml
  - macro: wz_user_known_activity
    condition: (proc.exepath = /opt/backup/bin/agent)
  ```

- Three pieces of noise are not optional on their respective platforms, and all three were found by measurement rather than reasoning. `snap-confine` loads a seccomp/bpf program on every snap launch and produced 264 of 306 events in a soak on Ubuntu, so its path is in `wz_known_bpf_loader_paths`. `sshd` attaches the client socket to the session's stdio on every login, which is four CRITICAL events per login, so its path is in `wz_session_daemon_paths`. And on Ubuntu the MOTD scripts run enumeration tools on every SSH login: one login produced **10** reconnaissance events, six of them `uname` from `/etc/update-motd.d/00-header`, which is exactly the original threshold of burst rule `225300` and therefore alerted at level 10 on every login. `uname`, `hostname` and `lsb_release` were dropped from the Falco rule's list (a login is now 4 events) and the burst threshold raised to 15. Re-measure this on your own images: a different MOTD or shell profile moves the baseline, and the burst rule is only useful above it.

- **Exclusions match on `proc.exepath`, detections match on `proc.name`.** This asymmetry is deliberate. `proc.name` is `comm`, which the process controls, so a payload copied to `./sshd` reports `proc.name=sshd`. For a detection that is an accepted limitation shared by every name-based rule and the consequence is a missed detection; for an *exclusion* the consequence is an attacker disabling a rule by choosing a filename, which would have been the case for the eBPF-rootkit and reverse-shell rules. Every exclusion list therefore holds resolved executable paths, and ancestry uses `proc.aexepath` rather than `proc.aname`. Keep it that way when adding entries: take the path from `proc.exepath` in a real event rather than writing the name you expect. Paths for both usr-merged and RHEL-style layouts are listed; an entry that does not exist on a host simply never matches.

The auditd ruleset deliberately leaves `-e 2` (immutable rules) commented out in `auditd/rules/audit.rules`. Enable it once the ruleset is stable — afterwards rule changes need a reboot.

### Two limitations of auditd path rules worth knowing

Both are properties of auditd, not bugs in the ruleset, and both are flagged by the test script rather than failing silently.

A `-w` watch and a `-F path=` rule bind to the inode resolved when the rule is loaded, and neither follows symlinks. On a usr-merged distribution `insmod`, `modprobe` and `rmmod` are all symlinks to `/usr/bin/kmod`, so the `/sbin/*` entries match nothing — the ruleset watches `/usr/bin/kmod` as well for that reason. The same applies to `/usr/bin/python3`, which is a symlink to a versioned binary, so the `interpreter` watch does not fire for `python3`. Pinning the versioned path works but breaks on the next minor upgrade; Falco reports the resolved `proc.exepath` instead.

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

It does **not** cover anything kernel-coupled, because a container shares the host kernel: auditd rules actually loading, the Falco driver attaching, or any event firing. The driver choice is even made from the *host's* kernel version and BTF rather than the target distribution's. auditd and LAUREL are skipped for that reason, and both sensor test scripts still need a real VM of the target distribution.

> **Never add `--privileged` to this harness.** The kernel audit subsystem is not namespaced — there is one audit netlink socket per kernel, shared with the host. A privileged container has `CAP_AUDIT_CONTROL`, so `augenrules --load` inside it does not configure the container, it replaces the audit rules of the machine you are sitting at, and `auditctl -e 2` would lock them until that machine reboots. The harness runs unprivileged (`--cap-add SYS_ADMIN` is enough for systemd as PID 1) and asserts that `CAP_AUDIT_CONTROL` is dropped before it will run the installer at all.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Removes the agent, the repo definitions, `99-wazuh.rules`, the LAUREL binary, config, plugin registration and system user, and the Falco package together with this repo's ruleset, config drop-in and logrotate rule. The `falcoctl-artifact-follow` mask applied at install time is reverted, so a later manual Falco install behaves the way its own package intends.

A ruleset at `/etc/audit/rules.d/audit.rules` is only removed if it carries this installer's marker line, so a distribution-provided ruleset is left alone. `/var/log/laurel` and `/var/log/falco` are both preserved: they may hold forensic data.

## License

Business Source License 1.1 — see [LICENSE](LICENSE). Free for personal non-commercial use, non-profits and NGOs, and customers under a current service agreement; other production use requires a commercial license. Converts to Apache 2.0 on 2030-05-05. Contact sales@isecng.de.

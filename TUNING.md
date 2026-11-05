# Tuning

Levels, thresholds, rule order and the known noise sources — what to measure on
your own hosts before trusting the defaults. See [README.md](README.md) for what
the rules cover and [wazuh/README.md](wazuh/README.md) for deploying them.

---

## Broad execve collection is disabled by default

`auditd/rules/audit.rules` ships with the broad `-S execve -F auid>=1000 -k exec` rules commented out, for two reasons.

The kernel evaluates audit rules first-match-wins. Those rules sit ahead of every `-p x` watch in the file and match any `execve`, so they tagged all those events `key=exec` and the specific keys — `priv_esc`, `audittools`, `user_mgmt`, `firewall`, `network_tools`, `exfil_tools`, `recon`, `interpreter`, `power`, `wazuh_exec` — were never set at all. Every Wazuh rule written against those keys was dead, which is why they used to match on `SYSCALL.exe` instead. With the broad rules disabled, the keys fire and the per-category forensic trail works.

Falco also reports the same executions with the parent process and full command line on one event, which auditd does not expose as queryable fields.

Re-enable them only if a compliance framework explicitly requires a complete command trail from the audit subsystem — auditd can guarantee delivery under load with `-f 2`, whereas Falco drops events under pressure. If you do, the per-tool keys go quiet again and their Wazuh rules should be demoted or removed. The block in section 4 of the ruleset explains this inline.

## Tuning before production

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

## Two limitations of auditd path rules worth knowing

Both are properties of auditd, not bugs in the ruleset, and both are flagged by the test script rather than failing silently.

A `-w` watch and a `-F path=` rule bind to the inode resolved when the rule is loaded, and neither follows symlinks. On a usr-merged distribution `insmod`, `modprobe` and `rmmod` are all symlinks to `/usr/bin/kmod`, so the `/sbin/*` entries match nothing — the ruleset watches `/usr/bin/kmod` as well for that reason. The same applies to `/usr/bin/python3`, which is a symlink to a versioned binary, so the `interpreter` watch does not fire for `python3`. Pinning the versioned path works but breaks on the next minor upgrade; Falco reports the resolved `proc.exepath` instead.


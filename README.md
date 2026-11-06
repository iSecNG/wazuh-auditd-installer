# wazuh-linux-sensors

Linux installer that deploys a [Wazuh](https://wazuh.com/) agent with two complementary sensors: auditd with [LAUREL](https://github.com/threathunters-io/laurel) for the audit trail, and [Falco](https://falco.org/) for behavioural detection. Supports Ubuntu/Debian, RHEL/CentOS/AlmaLinux/Rocky, Fedora, Amazon Linux, and openSUSE/SLES.

## Quick start

```bash
sudo bash install.sh --manager <manager-ip-or-fqdn>
```

This installs:
1. The **Wazuh agent** (configured and enrolled against your manager)
2. **auditd** with the hardened ruleset from this repo, as `/etc/audit/rules.d/99-wazuh.rules`
3. **LAUREL** (upstream's static release binary on x86_64, built from source on other architectures; registered as an auditd plugin)
4. **Falco** (from the official package repo, `modern_ebpf` driver) with this repo's ruleset in `/etc/falco/rules.d/`
5. A `<localfile>` entry in `ossec.conf` for each sensor, so the agent forwards `/var/log/laurel/audit.log` and `/var/log/falco/events.json`

Exit status is `0` only if the agent, auditd, LAUREL and Falco are all running afterwards **and** the agent is enrolled — a running agent whose key the manager refused retries indefinitely while systemd still reports it active, so `client.keys` is checked too.

For fleet deployment there is an Ansible role in [`ansible/`](ansible/README.md) that
reaches the same end state — agent, auditd ruleset, LAUREL and Falco — reading the
same payloads out of this repo. It installs the agent package offline from local
binaries rather than from the Wazuh repo, and has no uninstall path: use
`install.sh --uninstall` on the host for that.

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

```bash
sudo bash install.sh --manager <addr> [OPTIONS]
sudo bash install.sh --uninstall [OPTIONS]
```

The flags most deployments need:

| Flag | Purpose |
|---|---|
| `--manager <addr>` | Wazuh manager IP or FQDN — required on install |
| `--agent-group <groups>` | Comma-separated group list |
| `--wazuh-version <ver>` | Pin the agent version (default: latest) |
| `--package-path <path>` | Install from a local `.deb`/`.rpm` (air-gapped) |
| `--skip-auditd`, `--skip-laurel`, `--skip-falco` | Leave a sensor out, on install or uninstall |
| `--dry-run`, `--verbose` | Preview without changing anything, or echo each command |
| `--uninstall` | Remove everything this installer deployed |

`install.sh --help` lists the rest: ports, protocol, enrollment server and
password, SSL enrollment certificates, agent name and the timing variables.

All `--flags` can also be set as environment variables (e.g. `WAZUH_MANAGER=10.0.0.1`). CLI flags take precedence.

Pass the enrollment password through the environment rather than the command line — an argument is visible in `ps` to every local user:

```bash
sudo WAZUH_REGISTRATION_PASSWORD="$(cat /root/.wazuh-pass)" bash install.sh --manager 10.0.0.1
```

### Re-running on a host that already has the agent

The `WAZUH_*` deployment variables are applied by the Wazuh package's post-install script. If `wazuh-agent` is already installed, that script does not run again, so a different `--manager` or `--agent-group` has no effect — the installer says so instead of reporting success. Edit `/var/ossec/etc/ossec.conf`, or purge the agent first.

## Sensor installation detail

How LAUREL is fetched and its version pinned, including the musl/`nsswitch`
trade-off: [laurel/README.md](laurel/README.md).

How the Falco driver is chosen and why `falcoctl` auto-updates are masked:
[falco/README.md](falco/README.md).

## Manager-side setup

The Wazuh rules go on the manager, in a fixed filename order, and need
`wazuh-analysisd -t` before a restart: [wazuh/README.md](wazuh/README.md).
That page also covers collecting the sensor logs through a shared `agent.conf`
instead of per-agent `ossec.conf` blocks.

## What the rules cover

**auditd + LAUREL** (`auditd/rules/audit.rules`, `223000-det-laurel-generic.xml`): login and authentication events, account and group management, sudoers and PAM, SSH configuration and root keys, service/cron/kernel-module persistence, credential and SSL key file access, network and firewall changes, time manipulation, DAC permission changes, mount and kexec, Wazuh agent integrity, the audit subsystem's own integrity, and Falco's integrity. Syscall rules are duplicated for `b32` so a 32-bit process on a 64-bit host cannot bypass them.

**Falco** (`falco/rules/wazuh-falco-rules.yaml`, `225000-det-falco-generic.xml`): reverse shells (both the `/dev/tcp` and the `dup`-onto-stdio shapes), execution from world-writable directories, shells spawned below non-shell applications, polkit privilege escalation, `ld.so.preload` modification, setuid/setgid backdoors, SSH private key reads, eBPF program loading, shell history tampering, tunnelling tools, and sensor tampering. The interactive-command, reconnaissance and data-transfer rules carry the per-command trail that auditd's broad `execve` rule used to provide.

MITRE ATT&CK technique IDs are mapped throughout both rulesets.

## Tuning before production

Levels and `frequency`/`timeframe` values are starting points, not measurements.
Rule order is load-bearing in both rulesets, upstream Falco rules win over this
repo's, and three noise sources are not optional on their platforms:
[TUNING.md](TUNING.md). It also covers why broad `execve` collection ships
disabled and the two auditd path-rule limitations.

## Testing

Two scripts trigger every rule category on an installed host, `wazuh-logtest`
confirms the manager maps the events to the intended rules, and a container
harness tests `install.sh` across distributions: see [TESTING.md](TESTING.md).

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Removes the agent, the repo definitions, `99-wazuh.rules`, the LAUREL binary, config, plugin registration and system user, and the Falco package together with this repo's ruleset, config drop-in and logrotate rule. The `falcoctl-artifact-follow` mask applied at install time is reverted, so a later manual Falco install behaves the way its own package intends.

A ruleset at `/etc/audit/rules.d/audit.rules` is only removed if it carries this installer's marker line, so a distribution-provided ruleset is left alone. `/var/log/laurel` and `/var/log/falco` are both preserved: they may hold forensic data.

## Built on open source

This project is glue around excellent open-source work. Many thanks to the people behind it:

| Project | What it does here | License |
|---|---|---|
| [Wazuh](https://github.com/wazuh/wazuh) | The agent that ships everything to the manager | GPL-2.0 |
| [Linux Audit](https://github.com/linux-audit/audit-userspace) (auditd) | Kernel audit trail | GPL-2.0+ |
| [LAUREL](https://github.com/threathunters-io/laurel) | Turns auditd records into enriched JSON | GPL-3.0+ |
| [Falco](https://github.com/falcosecurity/falco) and its [rules](https://github.com/falcosecurity/rules) | Runtime behavioural detection | Apache-2.0 |
| [Ansible](https://github.com/ansible/ansible) and [community.general](https://github.com/ansible-collections/community.general) | Fleet deployment | GPL-3.0+ |
| [MITRE ATT&CK®](https://attack.mitre.org/) | Technique IDs mapped in both rulesets | [ATT&CK terms of use](https://attack.mitre.org/resources/legal-and-branding/terms-of-use/) |

None of these are vendored: the installer fetches them from upstream at install time.
They keep their own licenses, which the license below does not change.
[`sbom.cdx.json`](sbom.cdx.json) lists them as a CycloneDX SBOM with versions,
pins and sources.

## License

Business Source License 1.1 — see [LICENSE](LICENSE). Free for personal non-commercial use, non-profits and NGOs, and customers under a current service agreement; other production use requires a commercial license. Converts to Apache 2.0 on 2030-05-05. Contact sales@isecng.de.

# wazuh-auditd-installer

Linux installer that deploys a [Wazuh](https://wazuh.com/) agent with hardened auditd logging and [LAUREL](https://github.com/threathunters-io/laurel) on any mainstream Linux distribution. Supports Ubuntu/Debian, RHEL/CentOS/AlmaLinux/Rocky, Fedora, Amazon Linux, and openSUSE/SLES.

## Quick start

```bash
sudo bash install.sh --manager <manager-ip-or-fqdn>
```

This installs:
1. The **Wazuh agent** (configured and enrolled against your manager)
2. **auditd** with the hardened ruleset from this repo, as `/etc/audit/rules.d/99-wazuh.rules`
3. **LAUREL** (built from its latest release tag, registered as an auditd plugin)
4. A `<localfile>` entry in `ossec.conf` so the agent forwards `/var/log/laurel/audit.log`

Exit status is `0` only if the agent, auditd and LAUREL are all running afterwards.

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
  --dry-run                           Print actions without making changes
  --verbose                           Echo each command before running it
  -h, --help                          Show full help

Uninstall options:
  --uninstall                         Remove Wazuh agent, auditd rules, and LAUREL
  --skip-auditd                       Skip auditd rules removal
  --skip-laurel                       Skip LAUREL removal
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

## Manager-side setup

Deploy the Wazuh decoder and rules to your **Wazuh manager**, with the ownership the manager expects:

```bash
install -o wazuh -g wazuh -m 0660 wazuh/decoders/laurel_decoder.xml /var/ossec/etc/decoders/
install -o wazuh -g wazuh -m 0660 wazuh/rules/laurel_rules.xml      /var/ossec/etc/rules/
/var/ossec/bin/wazuh-logtest -t      # verify the ruleset loads before restarting
systemctl restart wazuh-manager
```

Then confirm the field paths against a real event, by pasting one line of `/var/log/laurel/audit.log` into `wazuh-logtest`:

```bash
/var/ossec/bin/wazuh-logtest
```

The rules assume LAUREL emits `SYSCALL.key` as a plain string and that `SYSCALL.exe`, `SYSCALL.comm` and `SYSCALL.tty` exist. If your LAUREL version differs, adjust the anchored regexes in `wazuh/rules/laurel_rules.xml`.

### Collecting the LAUREL log through centralized configuration

LAUREL logs JSON to `/var/log/laurel/audit.log`. To collect it centrally, add this to `/var/ossec/etc/shared/<group>/agent.conf` and remove the installer's block from each agent's `ossec.conf`:

```xml
<agent_config>
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/laurel/audit.log</location>
  </localfile>
</agent_config>
```

## What the rules cover

The auditd ruleset and Wazuh detection rules cover: interactive command logging, privilege escalation, service/cron/kernel module changes, credential file access, SSH/PAM/sudoers modifications, SSL key access, network and firewall changes, time manipulation, DAC permission changes, data exfiltration indicators, reconnaissance tools, and Wazuh agent integrity monitoring. MITRE ATT&CK technique IDs are mapped throughout. Syscall rules are duplicated for `b32` so a 32-bit process on a 64-bit host cannot bypass them.

### Tuning before production

Levels and the `frequency`/`timeframe` values in `laurel_rules.xml` are starting points, not measurements:

- Rule `100122` alerts at level 3 on **every** interactive command. It dominates alert volume; that is the intent, but size your indexer for it.
- The composite rules `100350`–`100353` fire on bursts. Baseline them against your own hosts first.
- Rule order in `laurel_rules.xml` is load-bearing. The broad `exec` catch-alls sit at the end of the file on purpose; `analysisd` keeps the first matching child of a parent rule, so moving them up disables every `exe`-matching rule above them.

The ruleset deliberately leaves `-e 2` (immutable rules) commented out in `auditd/rules/audit.rules`. Enable it once the ruleset is stable — afterwards rule changes need a reboot.

## Testing auditd rules

Run on the monitored host after installation:

```bash
sudo bash auditd/test/audit-test.sh --verbose
```

Triggers each rule category and confirms the expected audit key was recorded. It leaves no changes behind: existing files are poked with `touch -r FILE FILE` (fires the attribute watch, mtime unchanged, no FIM alert), temporary files are removed on exit, and a missing path is reported as `SKIP` rather than aborting the run.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Removes the agent, the repo definition, `99-wazuh.rules`, the LAUREL binary, config, plugin registration and system user. A ruleset at `/etc/audit/rules.d/audit.rules` is only removed if it carries this installer's marker line, so a distribution-provided ruleset is left alone. `/var/log/laurel` is preserved: it may hold forensic data.

## License

Business Source License 1.1 — see [LICENSE](LICENSE). Free for personal non-commercial use, non-profits and NGOs, and customers under a current service agreement; other production use requires a commercial license. Converts to Apache 2.0 on 2030-05-05. Contact sales@isecng.de.

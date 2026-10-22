# wazuh-installer-linux

Linux installer that deploys a [Wazuh](https://wazuh.com/) agent with hardened auditd logging and [LAUREL](https://github.com/threathunters-io/laurel) on any mainstream Linux distribution. Supports Ubuntu/Debian, RHEL/CentOS/AlmaLinux/Rocky, Fedora, Amazon Linux, and openSUSE/SLES.

## Quick start

```bash
sudo bash install.sh --manager <manager-ip-or-fqdn>
```

This installs:
1. The **Wazuh agent** (configured and enrolled against your manager)
2. **auditd** with the hardened ruleset from this repo
3. **LAUREL** (built from source, registered as an auditd plugin)

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
  --registration-password <pass>      Enrollment password
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
  -h, --help                          Show full help

Uninstall options:
  --uninstall                         Remove Wazuh agent, auditd rules, and LAUREL
  --skip-auditd                       Skip auditd rules removal
  --skip-laurel                       Skip LAUREL removal
  --dry-run                           Preview what would be removed
```

All `--flags` can also be set as environment variables (e.g. `WAZUH_MANAGER=10.0.0.1`). CLI flags take precedence.

## Manager-side setup

Deploy the Wazuh decoder and rules to your **Wazuh manager**:

```bash
cp wazuh/decoders/laurel_decoder.xml /var/ossec/etc/decoders/
cp wazuh/rules/laurel_rules.xml      /var/ossec/etc/rules/
systemctl restart wazuh-manager
```

Add the LAUREL log to the agent group configuration:

```xml
<localfile>
  <log_format>json</log_format>
  <location>/var/log/laurel/audit.log</location>
</localfile>
```

## What the rules cover

The auditd ruleset and Wazuh detection rules cover: interactive command logging, privilege escalation, service/cron/kernel module changes, credential file access, SSH/PAM/sudoers modifications, SSL key access, network and firewall changes, time manipulation, DAC permission changes, data exfiltration indicators, reconnaissance tools, and Wazuh agent integrity monitoring. MITRE ATT&CK technique IDs are mapped throughout.

## Testing auditd rules

Run on the monitored host after installation:

```bash
sudo bash auditd/test/audit-test.sh --verbose
```

Triggers each rule category with safe, reversible actions and confirms the expected audit key was recorded.

## License

GPLv3

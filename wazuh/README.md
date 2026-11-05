# Manager-Side Setup

The rules in `rules/` live on the **Wazuh manager**, not on the agents. This is
how to deploy them and confirm they match your sensors' events.

See [../README.md](../README.md) for the agent-side installer and
[../TUNING.md](../TUNING.md) for levels, thresholds and rule order.

---

## Deploying the rules

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


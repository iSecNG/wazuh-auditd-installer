# Wazuh Agent Binaries

Place the Wazuh agent packages here before running the playbook.

## Directory layout

```
binaries/
├── deb/
│   └── wazuh-agent_<version>_amd64.deb    # Debian / Ubuntu
└── rpm/
    └── wazuh-agent-<version>.x86_64.rpm   # RHEL / CentOS / SUSE
```

## Expected filename format

The filenames must match the pattern the role constructs from `wazuh_agent_version`:

| OS family   | Pattern                                      |
|-------------|----------------------------------------------|
| Debian      | `wazuh-agent_{{ wazuh_agent_version }}_amd64.deb` |
| RedHat/Suse | `wazuh-agent-{{ wazuh_agent_version }}.x86_64.rpm` |

Example for version `4.14.9-1`:
- `deb/wazuh-agent_4.14.9-1_amd64.deb`
- `rpm/wazuh-agent-4.14.9-1.x86_64.rpm`

Download packages from the official Wazuh repository and place them here before deployment.

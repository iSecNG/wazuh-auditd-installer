# Wazuh Agent Deployment — Ansible Role

Ansible equivalent of this repo's `install.sh`: deploys the Wazuh agent from local
binaries (no internet access needed on the target for the agent itself), the auditd
ruleset, LAUREL and Falco. Supports no-authentication, password-based, and
certificate-based agent registration. The ossec.conf can be supplied externally or
left to the built-in template.

Linux only — Debian/Ubuntu, RHEL-family and SUSE.

> **Note on internet access:** the agent package is installed offline from
> `roles/wazuh_agent/files/binaries/`, but LAUREL and Falco are fetched from
> upstream (GitHub releases and `download.falco.org`), exactly as `install.sh`
> does. Set `wazuh_install_laurel: false` / `wazuh_install_falco: false` on hosts
> without egress.

---

## Directory Structure

```
ansible/
├── .gitignore
├── TESTING.md                            # How to test this role
├── site.yml                              # Main entry point playbook
├── inventory/
│   ├── hosts.yml                         # Host and group definitions
│   ├── hosts-test.yml.template           # Template for test inventory
│   ├── vault.yml.template                # Template for vault-encrypted secrets
│   └── group_vars/
│       └── wazuh_agents.yml              # Deployment-specific variables
├── roles/
│   └── wazuh_agent/
│       ├── defaults/main.yml             # Role-internal defaults (ports, paths, sensors)
│       ├── handlers/main.yml             # Agent restart, audit rule load, Falco restart
│       ├── files/binaries/               # .deb / .rpm agent packages (gitignored)
│       ├── tasks/
│       │   ├── main.yml                  # Validation and orchestration
│       │   ├── install.yml               # Package selection, copy, installation
│       │   ├── configure.yml             # ossec.conf and certificate placement
│       │   ├── register.yml              # Registration via agent-auth (idempotent)
│       │   ├── auditd.yml                # auditd package + 99-wazuh.rules
│       │   ├── laurel.yml                # runs ../laurel/install-laurel.sh
│       │   └── falco.yml                 # repo, package, ruleset, config, logrotate
│       └── templates/ossec.conf.j2       # Built-in config incl. sensor <localfile>s
└── test/                                 # Container test nodes -- see TESTING.md
```

The sensor tasks read their payloads from the repo root (`../auditd`, `../laurel`,
`../falco`) rather than keeping a second copy under `roles/`, so the Ansible run and
`install.sh` always deploy the same ruleset. The path comes from
`wazuh_installer_repo`, which defaults to `{{ playbook_dir }}/..`.

---

## Prerequisites

- Ansible 2.12 or newer on the control node
- SSH access to target hosts with a user that can `sudo`
- Wazuh agent packages in `roles/wazuh_agent/files/binaries/`
- `community.general` on the control node (zypper module, needed even on
  Debian-only runs because Ansible resolves every module in an included task file):

```bash
ansible-galaxy collection install -r requirements.yml
```

### Binary Naming Convention

The role constructs the filename from `wazuh_agent_version`:

| OS Family      | Expected filename                                      |
|----------------|--------------------------------------------------------|
| Debian/Ubuntu  | `wazuh-agent_<version>_amd64.deb`                      |
| RHEL/CentOS    | `wazuh-agent-<version>.x86_64.rpm`                     |
| SUSE           | `wazuh-agent-<version>.x86_64.rpm`                     |

Example for version `4.14.4-1`:
- `roles/wazuh_agent/files/binaries/deb/wazuh-agent_4.14.4-1_amd64.deb`
- `roles/wazuh_agent/files/binaries/rpm/wazuh-agent-4.14.4-1.x86_64.rpm`

---

## Configuration

- **`inventory/group_vars/wazuh_agents.yml`** — deployment settings: manager
  address, agent version, registration method, which sensors to install. Main file
  to edit per environment.
- **`roles/wazuh_agent/defaults/main.yml`** — role-internal defaults: ports,
  certificate paths, sensor paths and versions. Rarely needs changes.

All variables can be overridden via `--extra-vars` (highest precedence),
`inventory/host_vars/<hostname>.yml`, or the group_vars file.

### Deployment Variables (set in group_vars)

| Variable | Default | Description |
|---|---|---|
| `wazuh_manager_address` | `<your-manager-here>` | FQDN or IP of the Wazuh manager |
| `wazuh_agent_version` | `4.14.9-1` | Must match the binary filename |
| `wazuh_agent_group` | `default` | Wazuh agent group |
| `wazuh_registration_method` | `none` | `none`, `password`, or `certificate` |
| `wazuh_install_auditd` | `true` | Install auditd and deploy `99-wazuh.rules` |
| `wazuh_install_laurel` | `true` | Install LAUREL as an auditd plugin |
| `wazuh_install_falco` | `true` | Install Falco with this repo's ruleset |
| `wazuh_sensor_localfiles` | `true` | Put the sensor-log `<localfile>` entries in the built-in ossec.conf. Set to `false` when the manager's shared `agent.conf` already collects them — defining a localfile in both places makes the agent tail the file twice. |

### Registration Variables (depending on method)

| Variable | Description |
|---|---|
| `wazuh_registration_password` | Registration password (password method only, via vault or extra-vars) |
| `wazuh_agent_cert_src` | Agent certificate on the control node (certificate method) |
| `wazuh_agent_key_src` | Agent private key on the control node (certificate method) |
| `wazuh_manager_ca_src` | Manager CA certificate on the control node (certificate method) |

### Role Defaults (rarely changed)

| Variable | Default | Description |
|---|---|---|
| `wazuh_manager_port` | `1514` | Agent-to-manager communication port |
| `wazuh_registration_port` | `1515` | Enrollment/registration port |
| `wazuh_agent_name` | `{{ inventory_hostname }}` | Agent name on the manager |
| `wazuh_custom_config_template` | `` (empty) | Custom ossec.conf Jinja2 template |
| `wazuh_installer_repo` | `{{ playbook_dir }}/..` | Repo root holding the sensor payloads |
| `laurel_version` / `laurel_sha256` | `` (empty) | Override the version pinned in `install-laurel.sh` — set both together |
| `laurel_build_from_source` | `false` | Force a source build instead of the release tarball |
| `laurel_log` | `/var/log/laurel/audit.log` | Path the agent tails |
| `falco_log` | `/var/log/falco/events.json` | Path the agent tails |

---

## Usage

### No-Authentication Registration

Requires the manager's authd configured without authentication. Trusted networks
and test environments only.

```yaml
# inventory/group_vars/wazuh_agents.yml
wazuh_manager_address: "wazuh.example.com"
wazuh_agent_version: "4.14.4-1"
wazuh_registration_method: "none"
```

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

### Password Registration

The password is written to `/var/ossec/etc/authd.pass` (0640, root:wazuh) on the
agent, where `agent-auth` and auto-enrollment pick it up. It never appears on a
command line or in Ansible output. With any other method a leftover `authd.pass`
is removed.

```yaml
wazuh_registration_method: "password"
wazuh_registration_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

```bash
ansible-playbook -i inventory/hosts.yml site.yml --ask-vault-pass
```

### Certificate Registration

```yaml
wazuh_registration_method: "certificate"
wazuh_agent_cert_src:   "files/certs/agent.pem"
wazuh_agent_key_src:    "files/certs/agent-key.pem"
wazuh_manager_ca_src:   "files/certs/rootCA.pem"
```

### Custom ossec.conf

Point `wazuh_custom_config_template` at a Jinja2 template relative to the playbook
directory. All role variables are available inside it — including `laurel_log` and
`falco_log`, whose `<localfile>` entries your template has to carry itself if you
want the sensor logs collected locally rather than via the manager's shared
`agent.conf`.

### Secrets Management

```bash
cp inventory/vault.yml.template inventory/vault.yml
# Fill in the values, then:
ansible-vault encrypt inventory/vault.yml
```

---

## What the sensor tasks do

Same end state as `install.sh`; see the [top-level README](../README.md) for what the
rules cover, [../laurel/README.md](../laurel/README.md) for how LAUREL is pinned and
[../falco/README.md](../falco/README.md) for the Falco driver requirements.

**auditd** — installs `auditd` (plus `audispd-plugins` on Debian), deploys
`../auditd/rules/audit.rules` to `/etc/audit/rules.d/99-wazuh.rules` and loads it
with `augenrules --load`. The service is never restarted: the RHEL-family unit sets
`RefuseManualStop=yes`.

**LAUREL** — runs this repo's `laurel/install-laurel.sh` on the target via the
`script` module, guarded by `creates: /usr/local/sbin/laurel`. The script is
self-contained and idempotent; it downloads the sha256-pinned static release on
x86_64 and builds from source otherwise. Re-expressing its download, verification
and fallback logic in YAML would mean maintaining it twice, so the role calls it.
Runs after auditd because LAUREL only works as an auditd plugin.

**Falco** — adds the upstream repository (armored key referenced by `signed-by`, so
no gpg needed on the target), installs the package with `FALCO_DRIVER_CHOICE` set
from a BTF check, deploys `../falco/rules/wazuh-falco-rules.yaml`,
`../falco/falco-local.yaml` as `/etc/falco/config.d/zz-wazuh.yaml` and the logrotate
rule, validates the ruleset *before* restarting, and masks
`falcoctl-artifact-follow` so the upstream ruleset is not auto-updated underneath
the deployment.

Driver selection: `modern_ebpf` when `/sys/kernel/btf/vmlinux` exists and the kernel
is ≥ 5.8, otherwise `kmod`, which DKMS-compiles a module at install time and on
every kernel update. The play prints a warning when it falls back; set
`wazuh_install_falco: false` on hosts where that is not acceptable.

---

## Testing

Docker nodes for the agent tasks, VMs for a full run including the sensors, plus
the dry-run behaviour: see [TESTING.md](TESTING.md).

---

## Notes

- The install task is version-aware: if exactly `wazuh_agent_version` is installed,
  copy and install are skipped; any other version is replaced (rolling out a new
  version = bump the variable). `client.keys` survives the upgrade.
- The registration task is idempotent: a populated `client.keys` means `agent-auth`
  is not called again.
- The built-in `ossec.conf` template is minimal: the manager connection plus the
  `<localfile>` entries for the LAUREL and Falco logs. FIM, rootcheck and the rest
  come from the group's shared `agent.conf` on the manager, or a custom template.
  This split is deliberate — `<client>`, `<client_buffer>` and `<logging>` are the
  sections Wazuh does *not* accept from a shared `agent.conf`, so they have to be
  local, while everything the template omits can be delivered centrally.
- If your shared `agent.conf` already collects `/var/log/laurel/audit.log` or
  `/var/log/falco/events.json`, set `wazuh_sensor_localfiles: false`. A localfile
  defined both locally and centrally makes the agent tail the file twice.
- Deploying over a host that `install.sh` set up replaces its `ossec.conf` with
  this template (the previous file is kept as a `.`-suffixed backup). The shell
  installer instead appends to the package default, so it is the non-destructive
  way to upgrade an existing host; the playbook is the right tool when the
  monitoring config comes from the manager.
- There is no uninstall path here. Use `sudo bash install.sh --uninstall` from the
  repo root on the target host.
- Packages are expected as `amd64`/`x86_64`; the filename logic supports no other
  architecture. LAUREL is built from source on non-x86_64.
- For production, store secrets with `ansible-vault` rather than on the command line.
- Files containing secrets (`authorized_keys`, vault files, certificates, binaries)
  are excluded via `.gitignore`.

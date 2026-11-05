# Testing the Wazuh Agent Role

How to exercise `site.yml` before it touches production. See [README.md](README.md)
for what the role deploys and how to configure it.

---

## Test Environment

```
test/
├── docker-compose.yml                # Test containers (agent tasks only)
├── Dockerfile.deb                    # Ubuntu 22.04 test node
├── Dockerfile.rpm                    # Rocky Linux 9 test node
├── authorized_keys_template          # Copy to authorized_keys before building
└── authorized_keys                   # (gitignored) your actual SSH public keys
```

Both options below need a reachable Wazuh manager (IP or FQDN).

> **Containers cannot test the sensors.** The audit netlink socket is global to the
> kernel, and Falco's drivers need host kernel access, so auditd, LAUREL and Falco
> are not meaningfully testable in Docker. Use Option A for the agent tasks with
> `wazuh_install_auditd=false wazuh_install_laurel=false wazuh_install_falco=false`,
> and Option B (VMs) for a full run. The repo's own `test/container-test.sh` covers
> what can be checked in a container -- see [../TESTING.md](../TESTING.md).

### Option A: Docker Containers (agent tasks only)

`test/` holds Dockerfiles for an Ubuntu 22.04 and a Rocky Linux 9 node. Both run
systemd as PID 1 (hence `privileged: true` — test use only) with sshd enabled, so
the agent tasks including service start/restart run as on a real host.

If the manager runs in Docker on the same host, use `host.docker.internal` as the
manager address — the test containers map it to the Docker host.

**Requirements:** Docker Engine and Docker Compose v2.

**1. Add your SSH public key**

```bash
cp test/authorized_keys_template test/authorized_keys
cat ~/.ssh/<your-ssh-key>.pub >> test/authorized_keys
```

**2. Build and start the containers**

```bash
cd test/
docker compose up -d --build
```

SSH is exposed on `2221` (Debian) and `2222` (RPM) on localhost.

**3. Create `inventory/hosts-test.yml`**

```bash
cp inventory/hosts-test.yml.template inventory/hosts-test.yml
```

**4. Run the playbook**

```bash
ansible-playbook -i inventory/hosts-test.yml site.yml \
  --extra-vars "wazuh_manager_address=host.docker.internal \
                wazuh_install_auditd=false wazuh_install_laurel=false wazuh_install_falco=false"
```

**5. Verify**

```bash
docker exec agent-deb systemctl status wazuh-agent
docker exec agent-deb cat /var/ossec/etc/client.keys
```

**6. Teardown**

```bash
cd test/ && docker compose down
```

### Option B: Virtual Machines (full run incl. sensors)

Any hypervisor works. Two VMs, e.g. Ubuntu 22.04 at `192.168.100.10` and Rocky
Linux 9 at `192.168.100.11`, SSH enabled and reachable from the control node.

```bash
ssh-copy-id <user>@192.168.100.10
ssh-copy-id <user>@192.168.100.11
```

```yaml
# inventory/hosts-test.yml
all:
  children:
    wazuh_agents:
      hosts:
        agent-deb:
          ansible_host: 192.168.100.10
          ansible_user: <user>
        agent-rpm:
          ansible_host: 192.168.100.11
          ansible_user: <user>
```

```bash
ansible-playbook -i inventory/hosts-test.yml site.yml \
  --extra-vars "wazuh_manager_address=<manager-ip>"
```

**Verify**

```bash
ssh <user>@192.168.100.10 "sudo systemctl status wazuh-agent; sudo auditctl -l | wc -l; \
  pgrep -a laurel; sudo systemctl is-active falco-modern-bpf; \
  sudo tail -2 /var/log/laurel/audit.log /var/log/falco/events.json"
```

On the manager, both agents should appear as active:

```bash
/var/ossec/bin/agent_control -l
```

The repo's `auditd/test/audit-test.sh` and `falco/test/falco-test.sh` generate
events to confirm the rules fire end to end; [../TESTING.md](../TESTING.md) covers
both.

### Dry Run

```bash
ansible-playbook -i inventory/hosts-test.yml site.yml --check \
  --extra-vars "wazuh_manager_address=<manager-ip>"
```

On hosts where the agent package would be installed or upgraded, the dry run stops
after reporting that, since every later step depends on the installed package. The
LAUREL `script` task is always skipped in check mode.


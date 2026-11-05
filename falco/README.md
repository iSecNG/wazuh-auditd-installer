# Falco

[Falco](https://falco.org/) provides the behavioural detection half of the
deployment. This directory holds the ruleset, the config drop-in and the
logrotate rule that `install.sh` and the Ansible role deploy.

See [../README.md](../README.md) for the installer and
[../TUNING.md](../TUNING.md) for how this ruleset interacts with upstream's.

---

## Driver and kernel requirements

Falco is installed from the official package repository. The installer selects the driver itself:

- **`modern_ebpf`** when the kernel is 5.8 or newer and `/sys/kernel/btf/vmlinux` exists. This is CO-RE: the probe is embedded in the Falco binary, so no compiler and no kernel headers are needed on the host, and a kernel upgrade changes nothing.
- **`kmod`** otherwise, which DKMS-compiles a kernel module at install time and again on every kernel update. It needs a compiler and the matching kernel headers. The installer warns when it falls back, since this is often not acceptable on a production host; use `--skip-falco` in that case.

The installer passes `FALCO_DRIVER_CHOICE`, `FALCOCTL_ENABLED=no` and `FALCO_FRONTEND=noninteractive` to the package, so it never prompts and the driver choice is reproducible rather than auto-detected per host.

`FALCOCTL_ENABLED=no` makes the package mask `falcoctl-artifact-follow.service`, which would otherwise replace `falco_rules.yaml` on its own schedule. The ruleset therefore stays pinned to whatever the installed package shipped, and detections do not change between hosts or without a deployment. To opt back in:

```bash
sudo systemctl unmask --now falcoctl-artifact-follow.service
```

Falco's upstream ruleset (`falco_rules.yaml`, around 90 rules) stays loaded alongside this repo's. See [../TUNING.md](../TUNING.md) for how the two interact.


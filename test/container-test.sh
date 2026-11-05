#!/usr/bin/env bash
# =============================================================================
# container-test.sh  --  Exercise install.sh across distributions in containers
#
# Builds a minimal systemd container per target distribution, runs install.sh
# inside it, asserts that every artefact landed, then runs the uninstaller and
# asserts that everything was removed and the forensic log preserved.
#
# Usage:
#   bash test/container-test.sh [--target IMAGE]... [--keep] [--verbose]
#
# --target   container base image, repeatable. Default: debian:12 debian:13
#            ubuntu:24.04 almalinux:9
# --keep     leave the containers running afterwards for poking around
#
# Requirements: docker, and a kernel with cgroup v2. Does not need root.
#
# ---------------------------------------------------------------------------
# WHY THIS DOES NOT RUN --privileged
# ---------------------------------------------------------------------------
# The kernel audit subsystem is NOT namespaced. There is one audit netlink
# socket per kernel, shared with the host. A privileged container has
# CAP_AUDIT_CONTROL, so `augenrules --load` inside it does not configure the
# container -- it REPLACES THE AUDIT RULES OF THE MACHINE YOU ARE SITTING AT,
# and `auditctl -e 2` would lock them until that machine reboots.
#
# So this harness runs unprivileged: --cap-add SYS_ADMIN is enough for systemd
# to boot as PID 1, and CAP_AUDIT_CONTROL stays dropped. The container then
# physically cannot reach the host's audit rules -- auditctl returns EPERM.
# The harness asserts that at startup and refuses to continue if it is ever
# not true.
#
# Do not "fix" a failing auditd test by adding --privileged.
#
# A container shares the host kernel, so nothing kernel-coupled is covered here:
# auditd rules loading, the Falco driver attaching, or any event firing. auditd
# and LAUREL are skipped for that reason, and both sensor test scripts still
# need a real VM. See "Testing the installer across distributions" in README.md.
# =============================================================================

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

declare -a TARGETS=()
# TEST-NET-1, unroutable on purpose: the agent installs and starts without
# enrolling, so running this cannot leave junk agents in a real manager.
MANAGER="192.0.2.1"
KEEP=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGETS+=("$2"); shift 2 ;;
        --keep)     KEEP=true;       shift ;;
        -v|--verbose) VERBOSE=true;  shift ;;
        -h|--help)  awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0 ;;
        *) echo "Unknown option: $1  (use --help)" >&2; exit 1 ;;
    esac
done

(( ${#TARGETS[@]} )) || TARGETS=(debian:12 debian:13 ubuntu:24.04 almalinux:9)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; (( PASS_COUNT++ )) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; (( FAIL_COUNT++ )) || true; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; (( SKIP_COUNT++ )) || true; }
note() { echo -e "       ${YELLOW}note:${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}--- $* ---${NC}"; }

command -v docker >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }
[[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]] \
    || { echo "cgroup v2 is required for systemd in a container." >&2; exit 1; }

declare -a STARTED=()
cleanup() {
    [[ "${KEEP}" == "true" ]] && { echo; note "containers left running: ${STARTED[*]:-none}"; return; }
    (( ${#STARTED[@]} )) && docker rm -f "${STARTED[@]}" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

# Run a command in the container; stdout+stderr merged.
cx() { docker exec "$1" bash -c "$2" 2>&1; }

# Assert a path exists / does not exist inside the container.
has()    { cx "$1" "[ -e '$2' ]" >/dev/null 2>&1; }
assert_has()    { has "$1" "$2" && pass "$3" || fail "$3"; }
assert_hasnt()  { has "$1" "$2" && fail "$3" || pass "$3"; }

test_target() {
    local image="$1"
    local name dockerfile family
    name="instest-$(echo "${image}" | tr -c 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/-$//')"

    case "${image}" in
        debian:*|ubuntu:*)                 family=deb; dockerfile=Dockerfile.deb ;;
        almalinux:*|rocky*|centos*|fedora:*) family=rpm; dockerfile=Dockerfile.rpm ;;
        *) skip "${image}: unknown family, no Dockerfile mapping"; return ;;
    esac

    section "${image}  (${family})"

    if ! docker build -q --build-arg "BASE=${image}" \
            -t "${name}:base" -f "${REPO_DIR}/test/${dockerfile}" \
            "${REPO_DIR}/test" >/dev/null 2>&1; then
        fail "${image}: image build failed"
        return
    fi

    docker rm -f "${name}" >/dev/null 2>&1
    # --cgroupns=host plus a writable cgroup mount is what systemd needs here.
    # No --privileged: see the header.
    if ! docker run -d --name "${name}" --hostname "${name}" \
            --cgroupns=host --cap-add SYS_ADMIN \
            --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
            -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
            -v "${REPO_DIR}":/repo:ro \
            "${name}:base" >/dev/null 2>&1; then
        fail "${image}: container failed to start"
        return
    fi
    STARTED+=("${name}")

    local i=0
    while (( i < 30 )); do
        [[ "$(cx "${name}" 'systemctl is-system-running' | tr -d '\r')" =~ (running|degraded) ]] && break
        sleep 1; (( i++ ))
    done
    if (( i >= 30 )); then
        fail "${image}: systemd did not come up"
        return
    fi
    pass "systemd running as PID 1"

    # ---- Safety gate: the container must not be able to reach host audit ----
    # If this ever passes, the harness is running with CAP_AUDIT_CONTROL and
    # install.sh would reconfigure the HOST's audit rules. Refuse to go on.
    # Checked against the capability bit rather than by probing auditctl,
    # because auditctl is not installed yet at this point and a probe would
    # pass for the wrong reason. CAP_AUDIT_CONTROL is bit 30; Docker's default
    # set grants CAP_AUDIT_WRITE (bit 29, write records only) but not this one.
    local capeff
    capeff="$(cx "${name}" 'grep CapEff /proc/1/status' | awk '{print $2}' | tr -d '\r')"
    if [[ -z "${capeff}" ]]; then
        fail "ABORT: could not read PID 1 capabilities"
        return
    elif (( 0x${capeff} & (1 << 30) )); then
        fail "ABORT: container has CAP_AUDIT_CONTROL (CapEff=${capeff})"
        note "install.sh would rewrite THIS MACHINE's audit rules. Not continuing."
        note "Remove --privileged / --cap-add AUDIT_CONTROL from the docker run above."
        return
    else
        pass "CAP_AUDIT_CONTROL dropped -- host audit rules unreachable"
    fi

    # ---- Install ----
    local out
    out="$(cx "${name}" "cd /repo && timeout 1200 bash install.sh \
            --manager '${MANAGER}' --agent-name '${name}' \
            --skip-auditd --skip-laurel")"
    [[ "${VERBOSE}" == "true" ]] && echo "${out}"

    grep -q 'Detected: ' <<<"${out}" \
        && pass "OS detection ran" || fail "OS detection ran"

    grep -qE 'wazuh-agent +: running' <<<"${out}" \
        && pass "wazuh-agent installed and active" \
        || fail "wazuh-agent installed and active"

    grep -q 'Package installed' <<<"${out}" \
        && pass "falco package installed non-interactively" \
        || fail "falco package installed non-interactively"

    grep -q 'Ruleset valid' <<<"${out}" \
        && pass "ruleset accepted by falco --validate" \
        || fail "ruleset accepted by falco --validate"

    grep -q 'falcoctl auto-update disabled' <<<"${out}" \
        && pass "falcoctl auto-update disabled" \
        || fail "falcoctl auto-update disabled"

    assert_has "${name}" /etc/falco/rules.d/wazuh-falco-rules.yaml "ruleset deployed"
    assert_has "${name}" /etc/falco/config.d/zz-wazuh.yaml         "output config deployed"
    assert_has "${name}" /etc/logrotate.d/falco-wazuh             "logrotate rule deployed"
    assert_has "${name}" /etc/systemd/system/falcoctl-artifact-follow.service \
                                                                  "falcoctl masked"

    cx "${name}" "grep -qE 'BEGIN wazuh-(auditd-installer|linux-sensors): FALCO' /var/ossec/etc/ossec.conf" >/dev/null 2>&1 \
        && pass "<localfile> block added to ossec.conf" \
        || fail "<localfile> block added to ossec.conf"

    # Validate independently of the installer's own report.
    cx "${name}" "falco -c /etc/falco/falco.yaml --validate \
            /etc/falco/rules.d/wazuh-falco-rules.yaml" \
        | grep -q '"successful":true' \
        && pass "independent falco --validate: successful" \
        || fail "independent falco --validate: successful"

    # Falco cannot actually start here: modern_ebpf needs to raise
    # RLIMIT_MEMLOCK, which needs CAP_SYS_RESOURCE. Assert the failure is
    # exactly that, so a genuine packaging break is still caught.
    local why
    why="$(cx "${name}" 'journalctl -u falco-modern-bpf.service -u falco-kmod.service --no-pager')"
    if grep -qi 'RLIMIT_MEMLOCK\|Operation not permitted\|modern bpf probe' <<<"${why}"; then
        skip "falco service start (expected: no CAP_SYS_RESOURCE in a container)"
        note "driver attach and event capture need a VM of this distribution"
    elif grep -qiE 'active \(running\)' <<<"$(cx "${name}" 'systemctl status falco-modern-bpf.service')"; then
        pass "falco service active (host kernel allowed the driver)"
    else
        fail "falco service failed for an unexpected reason"
        note "$(tail -3 <<<"${why}")"
    fi

    # ---- Uninstall ----
    cx "${name}" 'mkdir -p /var/log/falco && echo CONTAINER-TEST-SENTINEL > /var/log/falco/events.json' >/dev/null
    out="$(cx "${name}" "cd /repo && timeout 900 bash install.sh --uninstall \
            --skip-auditd --skip-laurel")"
    [[ "${VERBOSE}" == "true" ]] && echo "${out}"

    grep -q 'Uninstall complete' <<<"${out}" \
        && pass "uninstaller ran to completion" || fail "uninstaller ran to completion"

    assert_hasnt "${name}" /etc/falco/rules.d/wazuh-falco-rules.yaml "ruleset removed"
    assert_hasnt "${name}" /etc/falco/config.d/zz-wazuh.yaml         "output config removed"
    assert_hasnt "${name}" /etc/logrotate.d/falco-wazuh             "logrotate rule removed"
    assert_hasnt "${name}" /etc/systemd/system/falcoctl-artifact-follow.service \
                                                                    "falcoctl mask reverted"

    case "${family}" in
        deb) assert_hasnt "${name}" /etc/apt/sources.list.d/falcosecurity.list "falco apt repo removed"
             assert_hasnt "${name}" /etc/apt/sources.list.d/wazuh.list         "wazuh apt repo removed" ;;
        rpm) assert_hasnt "${name}" /etc/yum.repos.d/falcosecurity.repo        "falco yum repo removed"
             assert_hasnt "${name}" /etc/yum.repos.d/wazuh.repo                "wazuh yum repo removed" ;;
    esac

    # The forensic log must survive an uninstall, same as /var/log/laurel.
    [[ "$(cx "${name}" 'cat /var/log/falco/events.json' | tr -d '\r')" == "CONTAINER-TEST-SENTINEL" ]] \
        && pass "/var/log/falco preserved across uninstall" \
        || fail "/var/log/falco preserved across uninstall"
}

echo -e "${BOLD}Installer container tests${NC}"
echo -e "repo    : ${REPO_DIR}"
echo -e "manager : ${MANAGER}  (unroutable by design)"
echo -e "targets : ${TARGETS[*]}"

for t in "${TARGETS[@]}"; do
    test_target "${t}"
done

echo
echo -e "${BOLD}================================================================${NC}"
echo -e "  ${GREEN}pass: ${PASS_COUNT}${NC}   ${RED}fail: ${FAIL_COUNT}${NC}   ${YELLOW}skip: ${SKIP_COUNT}${NC}"
echo -e "${BOLD}================================================================${NC}"
note "auditd, LAUREL and both sensor test scripts are NOT covered here -- see the header."
(( FAIL_COUNT == 0 )) || exit 1

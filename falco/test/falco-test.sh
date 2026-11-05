#!/usr/bin/env bash
# =============================================================================
# falco-test.sh  --  Verify that the Falco ruleset is firing correctly
#
# For each rule in falco/rules/wazuh-falco-rules.yaml this script performs the
# minimal action that should fire it, waits for Falco to write the event, then
# greps /var/log/falco/events.json for the rule name.
#
# Usage:
#   sudo bash falco/test/falco-test.sh [--verbose]
#
# --verbose  prints the matching event's output line beneath each PASS
#
# Requirements:
#   - Must run as root
#   - Falco running with this repo's ruleset and the JSON file output
#     (/etc/falco/config.d/zz-wazuh.yaml), as deployed by install.sh
#
# Rule precedence:
#   Falco's rule_matching is "first": an event fires only the first matching
#   rule, in load order. falco_rules.yaml is loaded before /etc/falco/rules.d,
#   so an upstream rule can win over one of ours. That is expected for
#   credential-file reads, which upstream's "Read sensitive file untrusted"
#   covers -- this script checks for that rule by name instead.
#
# Safety:
#   - No sensor is ever stopped. The sensor-tampering rule is checked with a
#     harmless `systemctl --dry-run stop`, which matches on the command line
#     without acting on the unit.
#   - Temporary files are created under /tmp and removed on exit.
#   - The reverse-shell checks connect to a closed port on 127.0.0.2, so
#     nothing leaves the host.
#   - Binaries are run with --help / --version only.
#   - A missing binary SKIPs, never aborts the run.
# =============================================================================

set -uo pipefail

VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
        -h|--help)    awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; exit 0 ;;
        *)            echo "Unknown option: $arg  (use --help)" >&2; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

FALCO_LOG="/var/log/falco/events.json"

pass() { echo -e "${GREEN}[PASS]${NC} $*"; (( PASS_COUNT++ )) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; (( FAIL_COUNT++ )) || true; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; (( SKIP_COUNT++ )) || true; }
note() { echo -e "       ${YELLOW}note:${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}--- $* ---${NC}"; }

[[ $EUID -eq 0 ]] || { echo "This script must be run as root." >&2; exit 1; }

declare -a TMPFILES=()
stage() { TMPFILES+=("$1"); }

# One private working directory, created atomically by mktemp and readable only
# by root. Everything this script writes under /tmp goes inside it.
#
# This matters because the script runs as root and executes what it writes. A
# predictable path such as /tmp/.falco_test_payload_$$ can be pre-created by
# any local user as a symlink, and `cp` then writes through it: the chmod u+s
# further down would have set the setuid bit on the attacker's target instead
# of on our throwaway copy. mktemp fails rather than reusing an existing path,
# and 0700 keeps the directory contents out of reach while the test runs.
WORKDIR=$(mktemp -d /tmp/falco-test.XXXXXXXXXX) || {
    echo "Could not create a private working directory under /tmp." >&2
    exit 1
}
chmod 0700 "${WORKDIR}"
stage "${WORKDIR}"
# shellcheck disable=SC2317  # called via trap
cleanup() {
    (( ${#TMPFILES[@]} )) || return 0
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -n "$f" ]] && rm -rf -- "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ---- Preflight -------------------------------------------------------------
if ! command -v falco >/dev/null 2>&1; then
    echo "falco is not installed — nothing to test." >&2
    exit 1
fi
if [[ ! -f "${FALCO_LOG}" ]]; then
    echo "${FALCO_LOG} not found. Falco's file_output is not enabled;" >&2
    echo "deploy falco/falco-local.yaml to /etc/falco/config.d/zz-wazuh.yaml." >&2
    exit 1
fi

_unit=""
for u in falco-modern-bpf.service falco-kmod.service falco-custom.service; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then _unit="$u"; break; fi
done
if [[ -z "${_unit}" ]]; then
    echo "No Falco service is active — start it before running this test." >&2
    exit 1
fi
echo -e "${BOLD}Falco${NC}: $(falco --version 2>/dev/null | head -1)   unit: ${_unit}"

# Byte offset to read from, so each check only sees events it caused. Falco
# buffers briefly, so every check sleeps before reading.
MARK=$(wc -c < "${FALCO_LOG}")

# check_rule "RULE NAME" DESCRIPTION
#   Greps for RULE NAME in everything appended to the log since MARK, then
#   advances MARK past what it read.
check_rule() {
    local rule="$1" desc="$2"
    sleep 3
    local chunk
    chunk=$(tail -c "+$((MARK + 1))" "${FALCO_LOG}" 2>/dev/null || true)
    if grep -qF "\"rule\":\"${rule}\"" <<< "${chunk}"; then
        pass "${desc}"
        if $VERBOSE; then
            grep -F "\"rule\":\"${rule}\"" <<< "${chunk}" | tail -1 \
                | python3 -c 'import json,sys; print("       " + json.loads(sys.stdin.read())["output"][:300])' 2>/dev/null \
                || true
        fi
    else
        fail "${desc}  -- no event with rule \"${rule}\""
    fi
    MARK=$(wc -c < "${FALCO_LOG}")
}

# Advances MARK without asserting, for actions whose events we do not check.
skip_events() { sleep 1; MARK=$(wc -c < "${FALCO_LOG}"); }

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
section "Reverse shell and network"

# A shell calling connect() itself. The connection is refused, which is fine:
# Falco's rule matches the successful connect of a shell, so use a listener-free
# port on loopback-adjacent 127.0.0.2 and accept that this may not fire.
# bash's /dev/tcp needs a successful connect, so bind a throwaway listener.
if have python3; then
    python3 - <<'PY' >/dev/null 2>&1 &
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.2", 48112)); s.listen(2); time.sleep(12)
PY
    _listener=$!
    sleep 1
    # A real shell process performing the connect, which is the rule's shape.
    timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.2/48112' >/dev/null 2>&1 || true
    check_rule "Wazuh: Reverse shell connection from shell binary" \
               "Shell binary opened an outbound connection"
    # Redirecting a shell's stdio onto that socket is the dup() shape.
    timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.2/48112; exec 1>&3' >/dev/null 2>&1 || true
    check_rule "Wazuh: Standard stream redirected to network connection" \
               "Standard stream redirected onto a network socket"
    kill "${_listener}" 2>/dev/null || true
    wait "${_listener}" 2>/dev/null || true
else
    skip "Reverse shell checks  -- python3 not present to host the listener"
    skip "Standard stream redirect check  -- python3 not present"
fi

# --------------------------------------------------------------------------- #
section "Execution"

# Execution from a world-writable directory.
# Inside WORKDIR, which is still under /tmp, so the rule's
# "proc.exepath startswith /tmp/" condition is satisfied.
_payload="${WORKDIR}/payload"
if cp /bin/true "${_payload}" 2>/dev/null; then
    chmod 0755 "${_payload}"
    "${_payload}" || true
    check_rule "Wazuh: Process launched from world-writable directory" \
               "Binary executed from /tmp"
else
    skip "World-writable execution check  -- cannot write to /tmp"
fi

# A shell whose parent is a network service. Renaming a copy of a shell is not
# enough: the rule matches on the PARENT's name, so the parent must be the
# service binary. Simulated by copying bash to a service name and letting it
# spawn a child shell.
_fakesvc="${WORKDIR}/fakesvc"
if cp /bin/bash "${_fakesvc}" 2>/dev/null; then
    # The copy runs as comm="nginx" only if named exactly that; use a directory
    # so the basename is right.
    _svcdir="${WORKDIR}/svc"
    mkdir -m 0700 "${_svcdir}" && cp /bin/bash "${_svcdir}/nginx" 2>/dev/null
    # The trailing ":" matters. With a single command, bash exec()s it in place
    # instead of forking, so the shell REPLACES the fake service process and
    # the child's parent is this script, not "nginx". A second command forces
    # a real fork+exec, which is the parent/child shape the rule matches.
    "${_svcdir}/nginx" -c '/bin/sh -c "exit 0"; :' >/dev/null 2>&1 || true
    # Upstream's rule, not one of ours: see the note in
    # falco/rules/wazuh-falco-rules.yaml. Mapped by Wazuh rule 225141.
    check_rule "Run shell untrusted" \
               "Shell spawned below a non-shell app (upstream rule, Wazuh 225141)"
else
    skip "Service-shell check  -- cannot copy a shell into /tmp"
fi

# Interactive command on a terminal. Only meaningful with a tty attached.
if [[ -t 0 || -t 1 ]]; then
    ls /etc >/dev/null 2>&1 || true
    check_rule "Wazuh: Interactive command executed on terminal" \
               "Interactive command executed with a tty attached"
else
    skip "Interactive command check  -- no tty attached (run from a terminal)"
    note "proc.tty is 0 without a terminal, so the rule cannot match"
fi

# --------------------------------------------------------------------------- #
section "Credential access"

# Upstream's rule wins for these files; see the header note on precedence.
if [[ -r /etc/shadow ]]; then
    cat /etc/shadow >/dev/null 2>&1 || true
    check_rule "Read sensitive file untrusted" \
               "Shadow file read (upstream rule, mapped by Wazuh rule 225140)"
else
    skip "Credential read check  -- /etc/shadow not readable"
fi

_hostkey=$(ls /etc/ssh/ssh_host_*_key 2>/dev/null | head -1 || true)
if [[ -n "${_hostkey}" ]]; then
    cat "${_hostkey}" >/dev/null 2>&1 || true
    check_rule "Wazuh: SSH private key read by unexpected process" \
               "SSH host key read by an unexpected process"
else
    skip "SSH key read check  -- no host key found in /etc/ssh"
fi

# --------------------------------------------------------------------------- #
section "Persistence and privilege"

# Created inside the 0700 WORKDIR: the setuid bit is set on a copy of
# /bin/true that no other user can reach, and the directory goes away on exit.
_suid="${WORKDIR}/suid"
if cp /bin/true "${_suid}" 2>/dev/null; then
    chmod u+s "${_suid}" 2>/dev/null || true
    check_rule "Wazuh: Setuid or setgid bit set on file" \
               "Setuid bit set on a file"
else
    skip "Setuid check  -- cannot write to /tmp"
fi

if have pkexec; then
    # pkexec with no arguments exits immediately with usage; the rule matches
    # the execution by a non-root user, so run it as one if we can.
    _u=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)
    if [[ -n "${_u}" ]] && have runuser; then
        runuser -u "${_u}" -- pkexec --version >/dev/null 2>&1 || true
        check_rule "Wazuh: Polkit privilege escalation attempt" \
                   "pkexec executed by a non-root user"
    else
        skip "Polkit check  -- no non-root user available to run pkexec as"
    fi
else
    skip "Polkit check  -- pkexec not installed"
fi

# ld.so.preload: create and remove it, which is the write the rule looks for.
# Nothing is ever added to the file, so no library is actually preloaded.
if [[ ! -e /etc/ld.so.preload ]]; then
    : > /etc/ld.so.preload 2>/dev/null && stage /etc/ld.so.preload
    check_rule "Wazuh: Library preload file modified" \
               "ld.so.preload created"
    rm -f /etc/ld.so.preload
else
    skip "Library preload check  -- /etc/ld.so.preload already exists, left untouched"
    note "this file is a rootkit persistence path: confirm it is legitimate"
fi

# --------------------------------------------------------------------------- #
section "Anti-forensics and tooling"

_hist="/root/.bash_history"
if [[ -f "${_hist}" ]]; then
    # Append nothing and rewrite in place, so no history content is lost.
    touch "${_hist}"
    : >> "${_hist}"
    check_rule "Wazuh: Shell history tampered" \
               "Shell history file written"
else
    _fakehist="/root/.python_history"
    if [[ ! -e "${_fakehist}" ]]; then
        : > "${_fakehist}" 2>/dev/null && stage "${_fakehist}"
        check_rule "Wazuh: Shell history tampered" \
                   "History file created (/root/.python_history)"
    else
        skip "History check  -- no history file safe to touch"
    fi
fi

_tunnel=""
for b in nc ncat netcat socat; do have "$b" && { _tunnel="$b"; break; }; done
if [[ -n "${_tunnel}" ]]; then
    "${_tunnel}" -h >/dev/null 2>&1 || true
    check_rule "Wazuh: Tunnel or bind shell tool executed" \
               "Tunnel tool executed (${_tunnel})"
else
    skip "Tunnel tool check  -- no netcat or socat installed"
fi

if have curl; then
    curl --version >/dev/null 2>&1 || true
    check_rule "Wazuh: Data transfer tool executed" \
               "Data transfer tool executed (curl)"
else
    skip "Data transfer check  -- curl not installed"
fi

if have id; then
    id >/dev/null 2>&1 || true
    check_rule "Wazuh: Reconnaissance tool executed" \
               "Reconnaissance tool executed (id)"
fi

# --------------------------------------------------------------------------- #
section "Sensor integrity"

# Writing into /etc/falco. A dotfile, removed immediately; Falco does not read
# it, so the ruleset is unaffected.
# Must be under /etc/falco for the rule to match, and that directory is
# root-owned 0755 (unlike /tmp, which is world-writable), so a predictable
# name here cannot be pre-created by another user.
_probe="/etc/falco/.falco_test_$$"
stage "${_probe}"
if touch "${_probe}" 2>/dev/null; then
    check_rule "Wazuh: Security sensor configuration modified" \
               "Sensor configuration directory written"
    rm -f "${_probe}"
else
    skip "Sensor config check  -- cannot write to /etc/falco"
fi

# --dry-run makes systemctl print what it would do and exit without touching
# the unit, while still producing an execve with "stop" and the unit name on
# the command line, which is what the rule matches.
if systemctl --dry-run stop "${_unit}" >/dev/null 2>&1; then
    check_rule "Wazuh: Security sensor service stopped" \
               "Sensor stop command issued (systemctl --dry-run, unit untouched)"
else
    skip "Sensor stop check  -- systemctl --dry-run not supported here"
fi

# Confirm the dry run really left Falco alone.
if systemctl is-active --quiet "${_unit}"; then
    pass "Falco still running after the test (${_unit})"
else
    fail "Falco is NOT running after the test -- investigate before trusting results"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

echo
echo -e "${BOLD}================================================================${NC}"
echo -e "  ${GREEN}Passed : $PASS_COUNT${NC}"
echo -e "  ${RED}Failed : $FAIL_COUNT${NC}"
echo -e "  ${YELLOW}Skipped: $SKIP_COUNT${NC}"
echo -e "${BOLD}================================================================${NC}"

if (( FAIL_COUNT > 0 )); then
    echo
    echo "To debug a failing rule:"
    echo "  falco -c /etc/falco/falco.yaml --validate /etc/falco/rules.d/wazuh-falco-rules.yaml"
    echo "  journalctl -u ${_unit} -n 50        -- loader errors and drop statistics"
    echo "  tail -f ${FALCO_LOG}                -- watch events in real time"
    echo
    echo "A rule that fires in isolation but not here is usually shadowed by an"
    echo "earlier rule: Falco keeps only the FIRST match, and falco_rules.yaml"
    echo "is loaded before /etc/falco/rules.d."
fi

exit $(( FAIL_COUNT > 0 ? 1 : 0 ))

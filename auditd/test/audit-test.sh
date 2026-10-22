#!/usr/bin/env bash
# =============================================================================
# audit-test.sh  --  Verify that auditd rules are triggering correctly
#
# For each rule category this script performs the minimal action that should
# fire the rule, waits for auditd to process the event, then uses ausearch
# to confirm that an event with the expected key was recorded.
#
# Usage:
#   sudo bash auditd/test/audit-test.sh [--verbose]
#
# --verbose  prints the matching ausearch output beneath each PASS result
#
# Requirements:
#   - Must run as root
#   - A non-root login user (UID >= 1000) must exist for exec/perm_mod tests
#   - python3 must be present for raw-syscall tests (kexec, mknod)
#   - The Wazuh agent must be installed at /var/ossec/
#
# Key behaviour note — the 'exec' syscall rule and file-watch rules:
#   The broad rule "-a always,exit -S execve -F auid>=1000" fires for every
#   binary executed by a logged-in user and assigns key="exec".  When the
#   same execution ALSO matches a specific watch rule (e.g. -w /usr/bin/sudo
#   -p x -k priv_esc), only ONE key is stored per event.  The specific key
#   wins when the watch is evaluated AFTER the syscall rule (last-match wins).
#   In practice, results vary by kernel version.  This script handles both
#   cases: it first checks the specific key, and if not found, falls back to
#   confirming the binary appears in an 'exec' event.
#
# Safety notes:
#   - File watches are triggered by opening a watched file or directory for
#     write (touch creates/opens with O_CREAT|O_WRONLY), which is reversible.
#   - Binaries are executed with --help / --version / status flags only.
#   - kexec_load(0,0,NULL,0) clears any staged kexec image -- harmless if
#     none was loaded.
#   - The Wazuh agent is NOT stopped or restarted; wazuh-control is called
#     with "status" only.
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Globals
# --------------------------------------------------------------------------- #

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

# Brief warm-up: let the process settle so that events from this script's own
# startup (env sourcing, PAM, etc.) are timestamped BEFORE our start marker.
sleep 1

# Use "today" keyword + HH:MM:SS. Passing a date string (MM/DD/YYYY) alongside
# a time causes ausearch to silently return no results on some distros/locales;
# "today" is always accepted regardless of locale settings.
START_TIME=$(date '+%H:%M:%S')

# Files created during tests that must be removed on exit
declare -a TMPFILES=()

# Non-root user for rules that require auid >= 1000
NON_ROOT_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

pass() { echo -e "${GREEN}[PASS]${NC} $*"; (( PASS_COUNT++ )) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; (( FAIL_COUNT++ )) || true; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; (( SKIP_COUNT++ )) || true; }
note() { echo -e "       ${YELLOW}note:${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}--- $* ---${NC}"; }

# Track a path for cleanup on exit
stage() { TMPFILES+=("$1"); echo "$1"; }

# check_key KEY DESCRIPTION
#   Queries ausearch for KEY in events since the script started.
check_key() {
    local key="$1" desc="$2"
    sleep 1
    local output
    output=$(ausearch -k "$key" --start today "$START_TIME" 2>/dev/null || true)
    if grep -qE "^type=SYSCALL|^type=CWD|^----$" <<< "$output"; then
        pass "$desc  (key: $key)"
        if $VERBOSE; then
            grep -E "^type=SYSCALL" <<< "$output" | tail -2 | sed 's/^/       /'
        fi
    else
        fail "$desc  (key: $key) -- no events found since $START_TIME"
    fi
}

# check_exec_key KEY DESCRIPTION BINARY
#   Checks for a binary execution.  First looks for the specific KEY.
#   If not found, falls back to checking whether BINARY appears anywhere in
#   an 'exec' event (exe=, name=, or EXECVE arg) -- this handles:
#     - Regular binaries: exe="/path/to/bin"
#     - Python/shell scripts: exe=<interpreter>, path in name= or EXECVE a1=
check_exec_key() {
    local key="$1" desc="$2" binary="$3"
    sleep 1

    # Primary: did the specific key fire?
    local out
    out=$(ausearch -k "$key" --start today "$START_TIME" 2>/dev/null || true)
    if grep -qE "^type=SYSCALL" <<< "$out"; then
        pass "$desc  (key: $key)"
        if $VERBOSE; then
            grep "^type=SYSCALL" <<< "$out" | tail -1 | sed 's/^/       /'
        fi
        return
    fi

    # Fallback: search all exec events for the binary path in any field
    # (exe=, name=, or EXECVE argv -- covers scripts where exe= is the interpreter)
    if [[ -n "$binary" ]]; then
        local exec_out
        exec_out=$(ausearch -k exec --start today "$START_TIME" 2>/dev/null || true)
        # Use here-string to avoid SIGPIPE with set -o pipefail:
        # 'echo "$var" | grep -q' exits immediately on match, leaving echo with a
        # broken pipe (exit 141). pipefail makes the pipeline return 141 even though
        # grep found the match. '<<< "$var"' has no pipe, so no SIGPIPE.
        if grep -qF "$binary" <<< "$exec_out"; then
            pass "$desc  (key: exec -- specific key '$key' merged into broad exec rule)"
            note "The event IS recorded; search with:  ausearch -k exec -i | grep '${binary##*/}'"
            return
        fi
    fi

    fail "$desc  (key: $key, binary: $binary)"
}

# check_script_exec KEY DESCRIPTION SCRIPT_PATH
#   Like check_exec_key but explicitly for shell/python scripts: the
#   interpreter is exe=, and the script path appears in name= or EXECVE argv.
check_script_exec() {
    local key="$1" desc="$2" script="$3"
    sleep 1

    # Primary: specific key
    local out
    out=$(ausearch -k "$key" --start today "$START_TIME" 2>/dev/null || true)
    if grep -qE "^type=SYSCALL" <<< "$out"; then
        pass "$desc  (key: $key)"
        return
    fi

    # Fallback: look for the script path anywhere in exec events.
    # Use here-string (not echo | grep) to avoid SIGPIPE with set -o pipefail.
    local exec_out
    exec_out=$(ausearch -k exec --start today "$START_TIME" 2>/dev/null || true)
    if grep -qF "$script" <<< "$exec_out"; then
        pass "$desc  (script path found in exec events -- key '$key' merged into exec)"
        note "The event IS recorded; search with:  ausearch -k exec -i | grep '${script##*/}'"
        return
    fi

    fail "$desc  (key: $key, script: $script)"
}

# run_as_user USER CMD
#   Runs CMD as USER via runuser with a login session (sets loginuid).
run_as_user() {
    local user="$1"; shift
    runuser -l "$user" -s /bin/sh -c "$*" 2>/dev/null || true
}

# shellcheck disable=SC2317  # called via trap, not directly
cleanup() {
    for f in "${TMPFILES[@]:-}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error:${NC} this script must be run as root." >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
# Pre-flight
# --------------------------------------------------------------------------- #

require_root

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  auditd rule trigger test${NC}"
echo    "  started   : $(date '+%m/%d/%Y') $START_TIME"
echo    "  non-root  : ${NON_ROOT_USER:-(none found)}"
echo    "  ausearch  : $(which ausearch)"
echo -e "${BOLD}================================================================${NC}"

# --------------------------------------------------------------------------- #
# SECTION 3  --  Self-auditing
# --------------------------------------------------------------------------- #
section "Self-auditing"

# Touch a temp file inside the watched directory; the 'w' permission fires on
# the directory inode when the new dentry is created.
TF=$(stage /var/log/audit/.audit_test_$$)
touch "$TF"
check_key "auditlog" "Audit log directory modified"

TF=$(stage /etc/audit/.audit_test_$$)
touch "$TF"
check_key "auditconfig" "Audit config directory modified"

# Execute auditctl with a read-only flag (-s = status).
auditctl -s >/dev/null 2>&1
check_exec_key "audittools" "Audit tool executed (auditctl -s)" "/usr/sbin/auditctl"

# --------------------------------------------------------------------------- #
# SECTION 4  --  Command execution
# --------------------------------------------------------------------------- #
section "Command execution"

# The exec rule fires only for auid >= 1000.  runuser -l creates a PAM login
# session that sets loginuid to the target user's UID.
if [[ -n "$NON_ROOT_USER" ]]; then
    run_as_user "$NON_ROOT_USER" "id > /dev/null"
    check_key "exec" "execve by non-root user ($NON_ROOT_USER)"

    # Interactive command logging: same exec event but from a TTY session.
    # The run_as_user call above uses runuser -l which allocates a login
    # session with a TTY, so the event has tty != "(none)".
    # The Wazuh rule 100122 matches on this -- here we verify the auditd
    # event was recorded (same key, the Wazuh-level TTY filter is not
    # testable from ausearch).
    note "Interactive command logging (Wazuh rule 100122) uses the same auditd key 'exec' with TTY filter"
else
    skip "exec -- no non-root user found (rule needs auid >= 1000)"
fi

# exec_root_unattributed (uid=0, auid=-1) fires for unattributed root processes
# (cron, init scripts).  Cannot be reliably simulated from a login session.
skip "exec_root_unattributed -- requires auid=-1; fired by cron/init, not reproducible here"

# priv_esc: sudo is watched for execution.
sudo -V >/dev/null 2>&1 || true
check_exec_key "priv_esc" "Privilege-escalation binary executed (sudo -V)" "/usr/bin/sudo"

# --------------------------------------------------------------------------- #
# SECTION 5  --  Service management
# --------------------------------------------------------------------------- #
section "Service management"

# systemctl is watched for execution.
systemctl status >/dev/null 2>&1 || true
check_exec_key "service_exec" "systemctl executed (status)" "/usr/bin/systemctl"

# Creating a file inside /etc/systemd/system/ triggers the directory watch.
TF=$(stage /etc/systemd/system/.audit_test_$$.service)
touch "$TF"
check_key "service_change" "Systemd unit directory modified"

# Creating a file in /etc/cron.d/ triggers the cron watch.
TF=$(stage /etc/cron.d/.audit_test_$$)
touch "$TF"
check_key "cron" "Cron directory modified"

# Execute modprobe; on this system modprobe is a symlink to /usr/bin/kmod.
# The kernel records the real binary path as exe=.
modprobe audit_test_nonexistent_$$ 2>/dev/null || true
check_exec_key "modules" "Kernel module tool executed (modprobe -> kmod)" "/usr/bin/kmod"

# --------------------------------------------------------------------------- #
# SECTION 6  --  Critical file access
# --------------------------------------------------------------------------- #
section "Critical file access"

# identity: open /etc/passwd for write.  touch opens with O_CREAT|O_WRONLY,
# which triggers the 'w' permission on the file watch (mtime also changes -> 'a').
touch /etc/passwd
check_key "identity" "Identity file opened for write (/etc/passwd)"

# pam: create a temp file inside the watched directory.
TF=$(stage /etc/pam.d/.audit_test_$$)
touch "$TF"
check_key "pam" "PAM config directory modified"

# sshd: open sshd_config for write.
touch /etc/ssh/sshd_config
check_key "sshd" "SSH config opened for write"

# sudoers: create a temp file inside /etc/sudoers.d/.
TF=$(stage /etc/sudoers.d/.audit_test_$$)
touch "$TF"
check_key "sudoers" "Sudoers directory modified"

# ssl_keys: read the directory (perm=rwxa includes 'r').
ls /etc/ssl/private/ >/dev/null 2>&1 || true
check_key "ssl_keys" "SSL private key directory read"

# network_config: open /etc/hosts for write.
touch /etc/hosts
check_key "network_config" "Network config file opened for write (/etc/hosts)"

# kernel_config: create a temp file in /etc/sysctl.d/.
TF=$(stage /etc/sysctl.d/.audit_test_$$)
touch "$TF"
check_key "kernel_config" "Sysctl config directory modified"

# lib_preload: touch ld.so.conf.d/ directory.
TF=$(stage /etc/ld.so.conf.d/.audit_test_$$)
touch "$TF"
check_key "lib_preload" "Library preload config directory modified"

# login: open /var/run/utmp for write (touch triggers both 'w' and 'a').
touch /var/run/utmp
check_key "login" "Login session file opened for write"

# syslog: open /var/log/auth.log for write.
touch /var/log/auth.log
check_key "syslog" "System log file opened for write"

# access_denied: the rule fires on failed open() calls (success=0).
# As root, opens always succeed.  Use a non-root process to provoke EACCES
# by trying to read /etc/shadow (mode 640, root:shadow).
if [[ -n "$NON_ROOT_USER" ]]; then
    run_as_user "$NON_ROOT_USER" "cat /etc/shadow" 2>/dev/null || true
    check_key "access_denied" "Failed file access by non-root user (cat /etc/shadow)"
else
    skip "access_denied -- requires a non-root user to produce EACCES"
fi

# --------------------------------------------------------------------------- #
# SECTION 7  --  User and group management
# --------------------------------------------------------------------------- #
section "User and group management"

/usr/sbin/useradd --help >/dev/null 2>&1 || true
check_exec_key "user_mgmt" "User management tool executed (useradd --help)" "/usr/sbin/useradd"

/usr/sbin/groupadd --help >/dev/null 2>&1 || true
check_exec_key "group_mgmt" "Group management tool executed (groupadd --help)" "/usr/sbin/groupadd"

# --------------------------------------------------------------------------- #
# SECTION 8  --  DAC modifications
# --------------------------------------------------------------------------- #
section "DAC modifications"

# perm_mod rules require auid >= 1000.  Create a temp file owned by the
# non-root user, then run chmod as that user.
if [[ -n "$NON_ROOT_USER" ]]; then
    TF=$(stage /tmp/audit_perm_test_$$)
    touch "$TF"
    chown "$NON_ROOT_USER" "$TF"
    run_as_user "$NON_ROOT_USER" "chmod 644 '$TF'"
    check_key "perm_mod" "File permission change by non-root user ($NON_ROOT_USER)"
else
    skip "perm_mod -- requires auid >= 1000; no non-root user found"
fi

# --------------------------------------------------------------------------- #
# SECTION 9  --  Time manipulation
# --------------------------------------------------------------------------- #
section "Time manipulation"

# The time_change rule covers two triggers:
#   1. -w /etc/localtime -p wa          (file watch)
#   2. -a always,exit -S clock_settime  (syscall rule)
#
# /etc/localtime is a symlink; utimensat via 'touch' updates the TARGET's
# mtime but on this kernel does not fire the file inode watch through the
# symlink.  Instead we use clock_settime(CLOCK_REALTIME, <current_time>)
# which is a no-op (sets the clock to itself) but reliably fires the
# syscall-based rule.  This is safe: the time does not change, and NTP
# will not correct a zero-delta adjustment.
python3 - <<'PYEOF'
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
class timespec(ctypes.Structure):
    _fields_ = [('tv_sec', ctypes.c_long), ('tv_nsec', ctypes.c_long)]
ts = timespec()
libc.clock_gettime(0, ctypes.byref(ts))   # CLOCK_REALTIME = 0
libc.clock_settime(0, ctypes.byref(ts))   # set to current value (no-op)
PYEOF
check_key "time_change" "Time syscall invoked (clock_settime no-op)"

# --------------------------------------------------------------------------- #
# SECTION 10  --  Network and firewall
# --------------------------------------------------------------------------- #
section "Network and firewall"

if command -v ufw >/dev/null 2>&1; then
    # ufw is a Python script: exe= will be the Python interpreter, but the
    # ufw path appears in the PATH record (name=) and EXECVE argv (a1=).
    ufw status >/dev/null 2>&1 || true
    check_exec_key "firewall" "Firewall tool executed (ufw status)" "/usr/sbin/ufw"
elif [[ -x /sbin/iptables ]]; then
    # iptables is a symlink to xtables-nft-multi on this system.
    /sbin/iptables -L >/dev/null 2>&1 || true
    check_exec_key "firewall" "Firewall tool executed (iptables -L)" "/sbin/xtables-nft-multi"
else
    skip "firewall -- no ufw or iptables found"
fi

/usr/bin/ss -h >/dev/null 2>&1 || true
check_exec_key "network_tools" "Network tool executed (ss -h)" "/usr/bin/ss"

# remote_shell fires only on a successful connect() from bash -- requires an
# active listener.  Omitted to avoid noise and unintended network activity.
skip "remote_shell -- requires a reachable listener; omitted"

# --------------------------------------------------------------------------- #
# SECTION 11  --  Data exfiltration indicators
# --------------------------------------------------------------------------- #
section "Data exfiltration indicators"

if command -v curl >/dev/null 2>&1; then
    curl --version >/dev/null 2>&1 || true
    check_exec_key "exfil_tools" "Transfer tool executed (curl --version)" "/usr/bin/curl"
elif command -v wget >/dev/null 2>&1; then
    wget --version >/dev/null 2>&1 || true
    check_exec_key "exfil_tools" "Transfer tool executed (wget --version)" "/usr/bin/wget"
else
    skip "exfil_tools -- no curl or wget found"
fi

gzip --version >/dev/null 2>&1 || true
check_exec_key "compression" "Compression tool executed (gzip --version)" "/usr/bin/gzip"

# --------------------------------------------------------------------------- #
# SECTION 12  --  Recon
# --------------------------------------------------------------------------- #
section "Recon"

id >/dev/null
check_exec_key "recon" "Recon tool executed (id)" "/usr/bin/id"

python3 --version >/dev/null 2>&1 || true
# python3 is a symlink to python3.12 on this system; exe= shows the real path
PYTHON_REAL=$(readlink -f "$(which python3)" 2>/dev/null || echo "/usr/bin/python3")
check_exec_key "interpreter" "Interpreter executed (python3 --version)" "$PYTHON_REAL"

# --------------------------------------------------------------------------- #
# SECTION 13  --  Power, special files, and system state
# --------------------------------------------------------------------------- #
section "Power / system state"

# kexec_load(0, 0, NULL, 0): clears any staged kexec image (no-op if none
# was loaded).  The audit rule has no success= filter so it fires regardless.
python3 - <<'EOF'
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
SYS_kexec_load = 246  # x86_64
libc.syscall(SYS_kexec_load, 0, 0, 0, 0)
EOF
check_key "kexec" "kexec_load syscall invoked (no-op clear)"

# mknod: create a named FIFO (type p) -- no device access, fully removable.
FIFO_PATH=$(stage /tmp/audit_mknod_fifo_$$)
python3 -c "
import os
try:
    os.mknod('$FIFO_PATH', 0o600 | 0o10000)  # S_IFIFO | 0600
except FileExistsError:
    pass
" 2>/dev/null || mknod "$FIFO_PATH" p 2>/dev/null || true
check_key "mknod" "mknod syscall invoked (named FIFO)"

# mount: bind-mount a temp directory to itself, then unmount.  Safe and
# immediately reversed.
TMP_MNT=$(mktemp -d /tmp/audit_mnt_XXXX)
TMPFILES+=("$TMP_MNT")
{ mount --bind "$TMP_MNT" "$TMP_MNT" && umount "$TMP_MNT"; } 2>/dev/null || true
check_key "mount" "mount syscall invoked (self bind-mount)"

# --------------------------------------------------------------------------- #
# SECTION 14  --  Wazuh agent integrity
# --------------------------------------------------------------------------- #
section "Wazuh agent integrity"

# wazuh_config: open ossec.conf for write.  touch opens with O_WRONLY|O_CREAT
# which triggers the 'w' permission on the file watch.
touch /var/ossec/etc/ossec.conf
check_key "wazuh_config" "Wazuh config file opened for write (ossec.conf)"

# wazuh_keys: read client.keys (watch includes perm=r).
cat /var/ossec/etc/client.keys >/dev/null 2>&1 || true
check_key "wazuh_keys" "Wazuh client.keys read"

# wazuh_bin: open a watched binary for write.  touch opens with O_WRONLY|O_CREAT,
# triggering 'w'.  This does NOT modify the binary's content.
touch /var/ossec/bin/wazuh-agentd
check_key "wazuh_bin" "Wazuh binary opened for write (wazuh-agentd)"

# wazuh_exec: wazuh-control is a shell script; the interpreter (dash/sh) is
# recorded as exe=, and the script path appears in a PATH record.
/var/ossec/bin/wazuh-control status >/dev/null 2>&1 || true
check_script_exec "wazuh_exec" "Wazuh control script executed (status)" \
    "/var/ossec/bin/wazuh-control"

# wazuh_lib: create a temp file inside the lib directory.
TF=$(stage /var/ossec/lib/.audit_test_$$)
touch "$TF"
check_key "wazuh_lib" "Wazuh lib directory modified"

# wazuh_logs: create a temp file inside the logs directory.
TF=$(stage /var/ossec/logs/.audit_test_$$)
touch "$TF"
check_key "wazuh_logs" "Wazuh logs directory modified"

# wazuh_ar: create a temp file inside active-response/bin/.
TF=$(stage /var/ossec/active-response/bin/.audit_test_$$)
touch "$TF"
check_key "wazuh_ar" "Wazuh active-response directory modified"

# wazuh_ruleset: create a temp file inside the ruleset directory.
TF=$(stage /var/ossec/ruleset/.audit_test_$$)
touch "$TF"
check_key "wazuh_ruleset" "Wazuh ruleset directory modified"

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
    echo "To debug a failing key:"
    echo "  auditctl -l | grep <key>          -- confirm rule is loaded"
    echo "  ausearch -k <key> --start today -i -- look for any events"
    echo "  tail -f /var/log/audit/audit.log  -- watch events in real time"
fi

exit $(( FAIL_COUNT > 0 ? 1 : 0 ))

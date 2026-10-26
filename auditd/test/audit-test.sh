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
#   - The Wazuh agent must be installed at /var/ossec/ (those tests SKIP if not)
#
# Key shadowing:
#   The broad "-S execve -F auid>=1000" rule tags every command a logged-in
#   user runs with key="exec". The kernel stops at the first matching rule, so
#   the specific "-p x" watches after it (priv_esc, audittools, ...) never set
#   their key. Those events ARE recorded, under "exec". This script checks the
#   specific key first and falls back to searching the 'exec' events.
#
# Safety:
#   - Existing files are poked with `touch -r FILE FILE`: utimensat fires the
#     'a' watch while writing the file's own timestamps back, so mtime does
#     not change and no FIM alert is raised.
#   - Directory watches use a dot-prefixed temp file, removed on exit.
#   - Binaries run with --help / --version / status only.
#   - kexec_load(0,0,NULL,0) clears a staged image; no-op if none.
#   - The Wazuh agent is never stopped or restarted.
#   - A missing path SKIPs, never aborts.
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Globals
# --------------------------------------------------------------------------- #

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

# Brief warm-up: let the process settle so that events from this script's own
# startup (env sourcing, PAM, etc.) are timestamped BEFORE our start marker.
sleep 1

# Use "today" keyword + HH:MM:SS. Passing a date string (MM/DD/YYYY) alongside
# a time causes ausearch to silently return no results on some distros/locales;
# "today" is always accepted regardless of locale settings.
START_TIME=$(date '+%H:%M:%S')

# Paths created during tests that must be removed on exit
declare -a TMPFILES=()

# Non-root user for rules that require auid >= 1000
NON_ROOT_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)

# Distribution-dependent auth log location
AUTH_LOG=""
for f in /var/log/auth.log /var/log/secure; do
    [[ -f "$f" ]] && { AUTH_LOG="$f"; break; }
done

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

pass() { echo -e "${GREEN}[PASS]${NC} $*"; (( PASS_COUNT++ )) || true; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; (( FAIL_COUNT++ )) || true; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; (( SKIP_COUNT++ )) || true; }
note() { echo -e "       ${YELLOW}note:${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}--- $* ---${NC}"; }

# stage PATH -- register PATH for removal on exit.
# Call directly, never as $(stage ...): the subshell would discard the append.
stage() { TMPFILES+=("$1"); }

# shellcheck disable=SC2317  # called via trap, not directly
cleanup() {
    (( ${#TMPFILES[@]} )) || return 0
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -n "$f" ]] && rm -rf -- "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

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

# check_dir_watch DIR KEY DESCRIPTION
#   Fires a directory watch with a dot-prefixed temp file. SKIPs if DIR is
#   absent or unwritable.
check_dir_watch() {
    local dir="$1" key="$2" desc="$3"
    if [[ ! -d "$dir" ]]; then
        skip "$desc  -- $dir not present on this host"
        return
    fi
    local tf="${dir}/.audit_test_$$"
    stage "$tf"
    if ! touch "$tf" 2>/dev/null; then
        skip "$desc  -- cannot create a file in $dir"
        return
    fi
    check_key "$key" "$desc"
}

# check_file_watch FILE KEY DESCRIPTION
#   Fires the 'a' (attribute) permission with `touch -r FILE FILE`: utimensat
#   is issued but the timestamps written are the file's own, so nothing
#   changes. SKIPs if FILE is absent or unwritable.
check_file_watch() {
    local file="$1" key="$2" desc="$3"
    if [[ ! -e "$file" ]]; then
        skip "$desc  -- $file not present on this host"
        return
    fi
    if ! touch -r "$file" "$file" 2>/dev/null; then
        skip "$desc  -- cannot update timestamps on $file"
        return
    fi
    check_key "$key" "$desc"
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
            pass "$desc  (key: exec -- specific key '$key' shadowed by the broad exec rule)"
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
        pass "$desc  (script path found in exec events -- key '$key' shadowed by exec)"
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
command -v ausearch >/dev/null 2>&1 \
    || { echo -e "${RED}Error:${NC} ausearch not found — is auditd installed?" >&2; exit 1; }

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  auditd rule trigger test${NC}"
echo    "  started   : $(date '+%m/%d/%Y') $START_TIME"
echo    "  non-root  : ${NON_ROOT_USER:-(none found)}"
echo    "  ausearch  : $(command -v ausearch)"
echo    "  auth log  : ${AUTH_LOG:-(none found)}"
echo -e "${BOLD}================================================================${NC}"

# --------------------------------------------------------------------------- #
# SECTION 3  --  Self-auditing
# --------------------------------------------------------------------------- #
section "Self-auditing"

check_dir_watch /var/log/audit "auditlog"    "Audit log directory modified"
check_dir_watch /etc/audit     "auditconfig" "Audit config directory modified"

# Execute auditctl with a read-only flag (-s = status).
auditctl -s >/dev/null 2>&1 || true
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
    note "Interactive command logging (Wazuh rule 100122) uses the same auditd key 'exec' with a TTY filter"
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

systemctl status >/dev/null 2>&1 || true
check_exec_key "service_exec" "systemctl executed (status)" "/usr/bin/systemctl"

check_dir_watch /etc/systemd/system "service_change" "Systemd unit directory modified"
check_dir_watch /etc/cron.d         "cron"           "Cron directory modified"

# Execute modprobe; on most systems modprobe is a symlink to /usr/bin/kmod.
# The kernel records the real binary path as exe=.
modprobe audit_test_nonexistent_$$ 2>/dev/null || true
check_exec_key "modules" "Kernel module tool executed (modprobe -> kmod)" "/usr/bin/kmod"

# --------------------------------------------------------------------------- #
# SECTION 6  --  Critical file access
# --------------------------------------------------------------------------- #
section "Critical file access"

check_file_watch /etc/passwd          "identity"       "Identity file attribute change (/etc/passwd)"
check_dir_watch  /etc/pam.d           "pam"            "PAM config directory modified"
check_file_watch /etc/ssh/sshd_config "sshd"           "SSH config attribute change"
check_dir_watch  /etc/sudoers.d       "sudoers"        "Sudoers directory modified"

# ssl_keys: read the directory (perm=rwxa includes 'r').
if [[ -d /etc/ssl/private ]]; then
    ls /etc/ssl/private/ >/dev/null 2>&1 || true
    check_key "ssl_keys" "SSL private key directory read"
else
    skip "ssl_keys -- /etc/ssl/private not present on this host"
fi

check_file_watch /etc/hosts        "network_config" "Network config attribute change (/etc/hosts)"
check_dir_watch  /etc/sysctl.d     "kernel_config"  "Sysctl config directory modified"
check_dir_watch  /etc/ld.so.conf.d "lib_preload"    "Library preload config directory modified"
check_file_watch /var/run/utmp     "login"          "Login session file attribute change"

if [[ -n "$AUTH_LOG" ]]; then
    check_file_watch "$AUTH_LOG" "syslog" "System log file attribute change ($AUTH_LOG)"
else
    skip "syslog -- neither /var/log/auth.log nor /var/log/secure present"
fi

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

if [[ -x /usr/sbin/useradd ]]; then
    /usr/sbin/useradd --help >/dev/null 2>&1 || true
    check_exec_key "user_mgmt" "User management tool executed (useradd --help)" "/usr/sbin/useradd"
else
    skip "user_mgmt -- /usr/sbin/useradd not present"
fi

if [[ -x /usr/sbin/groupadd ]]; then
    /usr/sbin/groupadd --help >/dev/null 2>&1 || true
    check_exec_key "group_mgmt" "Group management tool executed (groupadd --help)" "/usr/sbin/groupadd"
else
    skip "group_mgmt -- /usr/sbin/groupadd not present"
fi

# --------------------------------------------------------------------------- #
# SECTION 8  --  DAC modifications
# --------------------------------------------------------------------------- #
section "DAC modifications"

# perm_mod rules require auid >= 1000.  Create a temp file owned by the
# non-root user, then run chmod as that user.
if [[ -n "$NON_ROOT_USER" ]]; then
    PERM_TF="/tmp/audit_perm_test_$$"
    stage "$PERM_TF"
    touch "$PERM_TF"
    chown "$NON_ROOT_USER" "$PERM_TF"
    run_as_user "$NON_ROOT_USER" "chmod 644 '$PERM_TF'"
    check_key "perm_mod" "File permission change by non-root user ($NON_ROOT_USER)"
else
    skip "perm_mod -- requires auid >= 1000; no non-root user found"
fi

# --------------------------------------------------------------------------- #
# SECTION 9  --  Time manipulation
# --------------------------------------------------------------------------- #
section "Time manipulation"

# /etc/localtime is a symlink and utimensat through it does not reliably fire
# the inode watch, so use the syscall side instead:
# clock_settime(CLOCK_REALTIME, <now>) sets the clock to itself. The time does
# not change and NTP has nothing to correct.
if command -v python3 >/dev/null 2>&1; then
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
else
    skip "time_change -- python3 not available for the raw syscall test"
fi

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
    # iptables is usually a symlink to xtables-nft-multi; exe= is the real path.
    /sbin/iptables -L >/dev/null 2>&1 || true
    IPT_REAL=$(readlink -f /sbin/iptables 2>/dev/null || echo /sbin/iptables)
    check_exec_key "firewall" "Firewall tool executed (iptables -L)" "$IPT_REAL"
else
    skip "firewall -- no ufw or iptables found"
fi

if command -v ss >/dev/null 2>&1; then
    ss -h >/dev/null 2>&1 || true
    check_exec_key "network_tools" "Network tool executed (ss -h)" "$(command -v ss)"
else
    skip "network_tools -- ss not found"
fi

# remote_shell fires only on a successful connect() from bash -- requires an
# active listener.  Omitted to avoid noise and unintended network activity.
skip "remote_shell -- requires a reachable listener; omitted"

# --------------------------------------------------------------------------- #
# SECTION 11  --  Data exfiltration indicators
# --------------------------------------------------------------------------- #
section "Data exfiltration indicators"

if command -v curl >/dev/null 2>&1; then
    curl --version >/dev/null 2>&1 || true
    check_exec_key "exfil_tools" "Transfer tool executed (curl --version)" "$(command -v curl)"
elif command -v wget >/dev/null 2>&1; then
    wget --version >/dev/null 2>&1 || true
    check_exec_key "exfil_tools" "Transfer tool executed (wget --version)" "$(command -v wget)"
else
    skip "exfil_tools -- no curl or wget found"
fi

if command -v gzip >/dev/null 2>&1; then
    gzip --version >/dev/null 2>&1 || true
    check_exec_key "compression" "Compression tool executed (gzip --version)" "$(command -v gzip)"
else
    skip "compression -- gzip not found"
fi

# --------------------------------------------------------------------------- #
# SECTION 12  --  Recon
# --------------------------------------------------------------------------- #
section "Recon"

id >/dev/null
check_exec_key "recon" "Recon tool executed (id)" "$(command -v id)"

if command -v python3 >/dev/null 2>&1; then
    python3 --version >/dev/null 2>&1 || true
    # python3 is usually a symlink to python3.X; exe= shows the real path
    PYTHON_REAL=$(readlink -f "$(command -v python3)" 2>/dev/null || echo "/usr/bin/python3")
    check_exec_key "interpreter" "Interpreter executed (python3 --version)" "$PYTHON_REAL"
else
    skip "interpreter -- python3 not found"
fi

# --------------------------------------------------------------------------- #
# SECTION 13  --  Power, special files, and system state
# --------------------------------------------------------------------------- #
section "Power / system state"

if command -v python3 >/dev/null 2>&1 && [[ "$(uname -m)" == "x86_64" ]]; then
    # Clears any staged kexec image. The rule has no success= filter, so it
    # fires either way.
    python3 - <<'EOF'
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
SYS_kexec_load = 246  # x86_64
libc.syscall(SYS_kexec_load, 0, 0, 0, 0)
EOF
    check_key "kexec" "kexec_load syscall invoked (no-op clear)"
else
    skip "kexec -- needs python3 on x86_64 (syscall number is arch-specific)"
fi

# mknod: create a named FIFO (type p) -- no device access, fully removable.
FIFO_PATH="/tmp/audit_mknod_fifo_$$"
stage "$FIFO_PATH"
if mknod "$FIFO_PATH" p 2>/dev/null; then
    check_key "mknod" "mknod syscall invoked (named FIFO)"
else
    skip "mknod -- could not create a FIFO in /tmp"
fi

# mount: bind-mount a temp directory to itself, then unmount.
TMP_MNT=$(mktemp -d /tmp/audit_mnt_XXXX)
stage "$TMP_MNT"
if mount --bind "$TMP_MNT" "$TMP_MNT" 2>/dev/null; then
    umount "$TMP_MNT" 2>/dev/null || true
    check_key "mount" "mount syscall invoked (self bind-mount)"
else
    skip "mount -- bind mount not permitted in this environment"
fi

# --------------------------------------------------------------------------- #
# SECTION 14  --  Wazuh agent integrity
# --------------------------------------------------------------------------- #
section "Wazuh agent integrity"

if [[ ! -d /var/ossec ]]; then
    skip "wazuh_* (8 checks) -- /var/ossec not present; Wazuh agent not installed"
    SKIP_COUNT=$(( SKIP_COUNT + 7 ))
else
    check_file_watch /var/ossec/etc/ossec.conf "wazuh_config" \
        "Wazuh config attribute change (ossec.conf)"

    # wazuh_keys: read client.keys (watch includes perm=r).
    if [[ -f /var/ossec/etc/client.keys ]]; then
        cat /var/ossec/etc/client.keys >/dev/null 2>&1 || true
        check_key "wazuh_keys" "Wazuh client.keys read"
    else
        skip "wazuh_keys -- /var/ossec/etc/client.keys not present (agent not enrolled)"
    fi

    check_file_watch /var/ossec/bin/wazuh-agentd "wazuh_bin" \
        "Wazuh binary attribute change (wazuh-agentd)"

    # wazuh-control is a shell script: exe= is the interpreter, the script
    # path shows up in a PATH record.
    if [[ -x /var/ossec/bin/wazuh-control ]]; then
        /var/ossec/bin/wazuh-control status >/dev/null 2>&1 || true
        check_script_exec "wazuh_exec" "Wazuh control script executed (status)" \
            "/var/ossec/bin/wazuh-control"
    else
        skip "wazuh_exec -- /var/ossec/bin/wazuh-control not present"
    fi

    check_dir_watch /var/ossec/lib                  "wazuh_lib"     "Wazuh lib directory modified"
    check_dir_watch /var/ossec/logs                 "wazuh_logs"    "Wazuh logs directory modified"
    check_dir_watch /var/ossec/active-response/bin  "wazuh_ar"      "Wazuh active-response directory modified"
    check_dir_watch /var/ossec/ruleset              "wazuh_ruleset" "Wazuh ruleset directory modified"
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
    echo "To debug a failing key:"
    echo "  auditctl -l | grep <key>           -- confirm rule is loaded"
    echo "  ausearch -k <key> --start today -i -- look for any events"
    echo "  tail -f /var/log/audit/audit.log   -- watch events in real time"
fi

exit $(( FAIL_COUNT > 0 ? 1 : 0 ))

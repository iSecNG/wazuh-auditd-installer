#!/usr/bin/env bash
# =============================================================================
# install-laurel.sh -- Build and install LAUREL from source
#
# Can be sourced by install.sh (exposes install_laurel()) or run standalone.
#
# Standalone usage:
#   sudo bash laurel/install-laurel.sh
#
# Requirements:
#   - Root privileges
#   - Internet access (to clone the repo and install packages)
#   - auditd must be installed and running
# =============================================================================

# Use lib/common.sh helpers when called from install.sh; otherwise define inline.
if [[ -n "${REPO_DIR:-}" && -f "${REPO_DIR}/lib/common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${REPO_DIR}/lib/common.sh"
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
    info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
    ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
    warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
    die()     { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
    section() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }
    run() {
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "${YELLOW}[DRY-RUN]${NC} $*" >&2; return 0
        fi
        "$@"
    }
fi

# ---------------------------------------------------------------------------
# Settings — globals so the EXIT trap can reference them after the function returns
# ---------------------------------------------------------------------------
_LAUREL_REPO="https://github.com/threathunters-io/laurel.git"
_LAUREL_USER="_laurel"
_LAUREL_BIN="/usr/local/sbin/laurel"
_LAUREL_CONF_DIR="/etc/laurel"
_LAUREL_CONF="${_LAUREL_CONF_DIR}/config.toml"
_LAUREL_LOG_DIR="/var/log/laurel"
_LAUREL_BUILD_DIR=""

_laurel_cleanup() {
    if [[ -d "${_LAUREL_BUILD_DIR:-}" ]]; then
        info "Cleaning up build directory ${_LAUREL_BUILD_DIR}"
        rm -rf "${_LAUREL_BUILD_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# install_laurel — idempotent; skips if binary already present
# ---------------------------------------------------------------------------
install_laurel() {
    section "LAUREL"

    if [[ -x "${_LAUREL_BIN}" ]]; then
        ok "LAUREL already installed at ${_LAUREL_BIN} — skipping"
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        info "[DRY-RUN] Would build and install LAUREL from ${_LAUREL_REPO}"
        info "[DRY-RUN] Would create user '${_LAUREL_USER}' and register auditd plugin"
        return 0
    fi

    # Detect auditd version to select the correct plugin directory.
    # auditd 3.x uses /etc/audit/plugins.d/; auditd 2.x uses /etc/audisp/plugins.d/.
    local auditd_major plugin_dir
    auditd_major=$(auditctl -v 2>/dev/null | grep -oP '\d+' | head -1 || echo "3")
    if (( auditd_major >= 3 )); then
        plugin_dir="/etc/audit/plugins.d"
    else
        plugin_dir="/etc/audisp/plugins.d"
    fi

    _LAUREL_BUILD_DIR=$(mktemp -d /tmp/laurel-build-XXXX)
    trap _laurel_cleanup EXIT

    # Step 1: build dependencies
    info "Installing build dependencies ..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y -qq git clang libacl1-dev pkg-config curl >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q git clang libacl-devel pkg-config curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q git clang libacl-devel pkg-config curl
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y git clang libacl-devel pkg-config curl
    else
        die "No supported package manager found for build dependencies."
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        info "Rust toolchain not found — installing via rustup ..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
        # shellcheck disable=SC1091
        source "${HOME}/.cargo/env"
    fi
    ok "Build dependencies ready  (rustc $(rustc --version | awk '{print $2}'))"

    # Step 2: clone and build
    info "Cloning LAUREL repository into ${_LAUREL_BUILD_DIR} ..."
    git clone --quiet --depth 1 "${_LAUREL_REPO}" "${_LAUREL_BUILD_DIR}"

    info "Building release binary (this may take a few minutes) ..."
    pushd "${_LAUREL_BUILD_DIR}" >/dev/null
    cargo build --release --quiet 2>&1
    popd >/dev/null

    local built_bin="${_LAUREL_BUILD_DIR}/target/release/laurel"
    [[ -x "${built_bin}" ]] || die "Build failed — ${built_bin} not found."
    ok "Build succeeded  ($(file -b "${built_bin}" | cut -d, -f1-2))"

    # Step 3: system user and log directory
    if id "${_LAUREL_USER}" >/dev/null 2>&1; then
        ok "System user '${_LAUREL_USER}' already exists"
    else
        info "Creating system user '${_LAUREL_USER}' ..."
        useradd --system --home-dir "${_LAUREL_LOG_DIR}" --create-home "${_LAUREL_USER}"
    fi
    install -d -o "${_LAUREL_USER}" -g "${_LAUREL_USER}" -m 0750 "${_LAUREL_LOG_DIR}"

    # Step 4: install binary
    info "Installing binary to ${_LAUREL_BIN} ..."
    install -m 0755 "${built_bin}" "${_LAUREL_BIN}"
    ok "Installed ${_LAUREL_BIN}  ($(${_LAUREL_BIN} --version 2>&1 || echo 'version unknown'))"

    # Step 5: write default configuration
    install -d -m 0755 "${_LAUREL_CONF_DIR}"
    if [[ -f "${_LAUREL_CONF}" ]]; then
        info "Backing up existing config ..."
        cp -a "${_LAUREL_CONF}" "${_LAUREL_CONF}.bak.$(date +%s)"
    fi
    info "Writing default configuration to ${_LAUREL_CONF} ..."
    cat > "${_LAUREL_CONF}" <<'TOML'
# LAUREL configuration
# See https://github.com/threathunters-io/laurel for full documentation.

directory = "/var/log/laurel"
user = "_laurel"
statusreport-period = 0
input = "stdin"

[auditlog]
file = "audit.log"
size = 5000000
generations = 10

[state]
file = "state"
generations = 0
max-age = 60

[transform]
execve-argv = [ "array" ]

[translate]
universal = false
user-db = false
drop-raw = false

[enrich]
pid = true
execve-env = [ "LD_PRELOAD", "LD_LIBRARY_PATH" ]
container = true
container_info = false
systemd = true
script = true
user-groups = true

[label-process]
label-keys = [ "software_mgmt" ]
propagate-labels = [ "software_mgmt" ]

[filter]
filter-null-keys = false
filter-action = "drop"
TOML
    ok "Configuration written to ${_LAUREL_CONF}"

    # Step 6: register as auditd plugin
    install -d -m 0755 "${plugin_dir}"
    info "Registering LAUREL as auditd plugin in ${plugin_dir}/laurel.conf ..."
    cat > "${plugin_dir}/laurel.conf" <<PLUGIN
active = yes
direction = out
type = always
format = string
path = ${_LAUREL_BIN}
args = --config ${_LAUREL_CONF}
PLUGIN
    ok "Plugin registered in ${plugin_dir}/laurel.conf"

    # Step 7: reload auditd to pick up the new plugin
    info "Signalling auditd to reload configuration ..."
    pkill -HUP auditd || true
    sleep 2

    if pgrep -x laurel >/dev/null 2>&1; then
        ok "LAUREL is running  (pid $(pgrep -x laurel | head -1))"
    else
        warn "LAUREL process not detected yet — verify with: pgrep -a laurel"
        warn "This may be normal if auditd takes longer to spawn plugins."
    fi
}

# ---------------------------------------------------------------------------
# Standalone entrypoint
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    [[ $EUID -eq 0 ]] || die "This script must be run as root."
    command -v auditctl >/dev/null 2>&1 \
        || die "auditd is not installed. Install it first or use install.sh."
    install_laurel
fi

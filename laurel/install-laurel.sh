#!/usr/bin/env bash
# =============================================================================
# install-laurel.sh -- Install LAUREL as an auditd plugin
#
# On x86_64 the upstream statically-linked musl release binary is downloaded and
# verified against a pinned sha256. Everything else builds from source.
#
# Can be sourced by install.sh (exposes install_laurel()) or run standalone.
#
# Standalone usage:
#   sudo bash laurel/install-laurel.sh
#
# Requirements:
#   - Root privileges
#   - Internet access (to fetch the release or clone the repo)
#   - auditd must be installed and running
#
# Environment:
#   LAUREL_VERSION=v0.8.3         install a different release (see _LAUREL_SHA256)
#   LAUREL_SHA256=<hex>           sha256 of that release's x86_64-musl tarball
#   LAUREL_BUILD_FROM_SOURCE=1    always build, even on x86_64
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
    run_ok() { run "$@" || true; }
    nap() { [[ "${DRY_RUN:-false}" == "true" ]] || sleep "$1"; }
fi

# ---------------------------------------------------------------------------
# Settings — globals so the EXIT trap can reference them after the function returns
# ---------------------------------------------------------------------------
_LAUREL_REPO="https://github.com/threathunters-io/laurel.git"
_LAUREL_RELEASE_URL="https://github.com/threathunters-io/laurel/releases/download"
# Pinned release. The prebuilt tarball is checksum-verified, so the version and
# the hash below belong together -- bump both, or pass LAUREL_VERSION with a
# matching LAUREL_SHA256. Upstream publishes no checksum or signature files, so
# this pin is the only thing standing between a release asset and /usr/local/sbin.
_LAUREL_PINNED_VERSION="v0.8.2"
_LAUREL_PINNED_SHA256="89f6bfbed42a5b6824aa847cecf43abc55dafe6778515c3514be43c037ef2662"
_LAUREL_VERSION="${LAUREL_VERSION:-${_LAUREL_PINNED_VERSION}}"
_LAUREL_SHA256="${LAUREL_SHA256:-}"
_LAUREL_USER="_laurel"
_LAUREL_BIN="/usr/local/sbin/laurel"
_LAUREL_CONF_DIR="/etc/laurel"
_LAUREL_CONF="${_LAUREL_CONF_DIR}/config.toml"
_LAUREL_LOG_DIR="/var/log/laurel"
_LAUREL_BUILD_DIR=""
# Path to the binary produced by whichever of the two paths below ran.
_LAUREL_BUILT_BIN=""

_laurel_cleanup() {
    if [[ -d "${_LAUREL_BUILD_DIR:-}" ]]; then
        info "Cleaning up build directory ${_LAUREL_BUILD_DIR}"
        rm -rf "${_LAUREL_BUILD_DIR}"
    fi
}

# Expected sha256 of the x86_64-musl tarball for _LAUREL_VERSION, or empty when
# none is known -- an unverifiable download is not installed.
_laurel_prebuilt_sha() {
    if [[ -n "${_LAUREL_SHA256}" ]]; then
        echo "${_LAUREL_SHA256}"
    elif [[ "${_LAUREL_VERSION}" == "${_LAUREL_PINNED_VERSION}" ]]; then
        echo "${_LAUREL_PINNED_SHA256}"
    fi
}

# Prints why the prebuilt binary cannot be used, or nothing when it can.
# Pure (reads globals and uname only) so test/laurel-prebuilt-test.sh can drive it.
_laurel_prebuilt_blocker() {
    if [[ "${LAUREL_BUILD_FROM_SOURCE:-0}" == "1" ]]; then
        echo "LAUREL_BUILD_FROM_SOURCE=1"
    # Upstream ships a static musl asset for x86_64 only. The aarch64 and armv7
    # assets are glibc builds that need GLIBC_2.30, which is newer than RHEL 8
    # and Debian 10 carry, so they are no more portable than a source build.
    elif [[ "$(uname -m)" != "x86_64" ]]; then
        echo "no static release asset for $(uname -m)"
    elif [[ -z "$(_laurel_prebuilt_sha)" ]]; then
        echo "no known sha256 for ${_LAUREL_VERSION} (set LAUREL_SHA256 to use the release tarball)"
    fi
}

# Download, verify and unpack the static release tarball. Sets _LAUREL_BUILT_BIN.
# Returns 1 if the download fails, so the caller can fall back to a source build.
_laurel_fetch_prebuilt() {
    local ver="${_LAUREL_VERSION#v}"
    local tgz="${_LAUREL_BUILD_DIR}/laurel.tar.gz"
    local url="${_LAUREL_RELEASE_URL}/${_LAUREL_VERSION}/laurel-${ver}-x86_64-musl.tar.gz"
    local want; want="$(_laurel_prebuilt_sha)"

    info "Downloading ${url} ..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${tgz}" "${url}"; then
        warn "Download of ${url} failed."
        return 1
    fi

    # A hash mismatch is a tampering or wrong-pin signal, not a transient
    # error: fail hard instead of quietly building something else.
    if ! echo "${want}  ${tgz}" | sha256sum -c --status -; then
        die "sha256 mismatch on ${url}
  expected ${want}
  got      $(sha256sum "${tgz}" | awk '{print $1}')
If you bumped LAUREL_VERSION, pass the matching LAUREL_SHA256."
    fi
    ok "sha256 verified  (${want})"

    tar xzf "${tgz}" -C "${_LAUREL_BUILD_DIR}" || die "Extracting ${tgz} failed."
    # The top-level directory carries version and flavour, and entries are
    # "./"-prefixed, so --strip-components would need 2. Glob it instead.
    local found=( "${_LAUREL_BUILD_DIR}"/*/bin/laurel )
    [[ -x "${found[0]}" ]] || die "No bin/laurel in ${url}."
    _LAUREL_BUILT_BIN="${found[0]}"
}

# Install a toolchain, clone the pinned tag and build. Sets _LAUREL_BUILT_BIN.
_laurel_build_from_source() {
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

    # A previous fetch attempt may have left the tarball and its contents here.
    local src="${_LAUREL_BUILD_DIR}/src"
    info "Cloning LAUREL ${_LAUREL_VERSION} into ${src} ..."
    git clone --quiet --depth 1 --branch "${_LAUREL_VERSION}" "${_LAUREL_REPO}" "${src}" \
        || die "Clone of ${_LAUREL_REPO} at ${_LAUREL_VERSION} failed."
    ok "Building LAUREL ${_LAUREL_VERSION}  (commit $(git -C "${src}" rev-parse --short HEAD))"

    info "Building release binary (this may take a few minutes) ..."
    pushd "${src}" >/dev/null
    cargo build --release --quiet 2>&1
    popd >/dev/null

    _LAUREL_BUILT_BIN="${src}/target/release/laurel"
    [[ -x "${_LAUREL_BUILT_BIN}" ]] || die "Build failed — ${_LAUREL_BUILT_BIN} not found."
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
        local dr_blocker; dr_blocker="$(_laurel_prebuilt_blocker)"
        if [[ -n "${dr_blocker}" ]]; then
            info "[DRY-RUN] Would build LAUREL ${_LAUREL_VERSION} from ${_LAUREL_REPO}: ${dr_blocker}"
        else
            info "[DRY-RUN] Would install the static LAUREL ${_LAUREL_VERSION} x86_64-musl release binary"
        fi
        info "[DRY-RUN] Would create user '${_LAUREL_USER}' and register auditd plugin"
        return 0
    fi

    # LAUREL only runs as an auditd plugin.
    if ! command -v auditctl >/dev/null 2>&1; then
        warn "auditd is not installed — skipping LAUREL."
        warn "Install auditd (drop --skip-auditd) and re-run, or install LAUREL with:"
        warn "  sudo bash laurel/install-laurel.sh"
        return 0
    fi

    # Select the plugin directory by what the installed auditd actually provides:
    # 3.x/4.x use /etc/audit/plugins.d/, 2.x uses /etc/audisp/plugins.d/.
    #
    # This used to parse `auditctl -v`, which failed silently: `head -1` exits 0
    # on empty input, so the `|| echo 3` fallback never fired. Whenever auditctl
    # produced no stdout (no CAP_AUDIT_CONTROL, or not in PATH) the version came
    # back empty, arithmetic read that as 0, and the config landed in the 2.x
    # directory that a modern auditd never reads -- LAUREL installed, reported
    # success and forwarded nothing. Testing for the directory has no such
    # failure mode and needs no version parsing.
    local plugin_dir
    if   [[ -d /etc/audit/plugins.d   ]]; then plugin_dir="/etc/audit/plugins.d"
    elif [[ -d /etc/audisp/plugins.d  ]]; then plugin_dir="/etc/audisp/plugins.d"
    else
        die "No auditd plugin directory found (looked for /etc/audit/plugins.d and /etc/audisp/plugins.d) -- is auditd installed?"
    fi

    _LAUREL_BUILD_DIR=$(mktemp -d /tmp/laurel-build-XXXX)
    trap _laurel_cleanup EXIT

    # Steps 1-2: obtain the binary, by download or by build.
    local blocker; blocker="$(_laurel_prebuilt_blocker)"
    if [[ -n "${blocker}" ]]; then
        info "Building LAUREL ${_LAUREL_VERSION} from source: ${blocker}"
        _laurel_build_from_source
    elif ! _laurel_fetch_prebuilt; then
        warn "Falling back to a source build."
        _laurel_build_from_source
    else
        # Static musl builds cannot use nsswitch: user and group lookups read
        # /etc/passwd and /etc/group only (upstream issue #84). On a host with a
        # remote user database, enrich.user-groups below goes silently blank.
        if grep -Eq '^(passwd|group):.*(sss|ldap|winbind|nis)' /etc/nsswitch.conf 2>/dev/null; then
            warn "This host resolves users via a remote database (nsswitch), which the"
            warn "static binary cannot query — group enrichment will be incomplete."
            warn "Re-run with LAUREL_BUILD_FROM_SOURCE=1 for a build that can."
        fi
    fi
    local built_bin="${_LAUREL_BUILT_BIN}"
    # Fields 1,2,4 are type, architecture and linkage — the last one is the
    # whole point of the prebuilt path, so keep it in the log.
    ok "Binary ready  ($(file -b "${built_bin}" | cut -d, -f1,2,4))"

    # Step 3: system user and log directory
    if id "${_LAUREL_USER}" >/dev/null 2>&1; then
        ok "System user '${_LAUREL_USER}' already exists"
    else
        info "Creating system user '${_LAUREL_USER}' ..."
        # No --create-home: it copies /etc/skel into the log directory and
        # leaves .bashrc/.profile there. nologin: this account never logs in.
        useradd --system --no-create-home --home-dir "${_LAUREL_LOG_DIR}" \
            --shell /usr/sbin/nologin "${_LAUREL_USER}"
    fi
    # LAUREL resets this directory to 0755 itself at runtime, so 0750 only
    # covers the window before it starts. The log files it writes are 0640
    # _laurel:_laurel, so the contents stay unreadable to other users either way.
    install -d -o "${_LAUREL_USER}" -g "${_LAUREL_USER}" -m 0750 "${_LAUREL_LOG_DIR}"
    # Clean up skel files left by an earlier --create-home install.
    rm -f "${_LAUREL_LOG_DIR}/.bashrc" "${_LAUREL_LOG_DIR}/.profile" \
          "${_LAUREL_LOG_DIR}/.bash_logout"

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
    nap 2

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

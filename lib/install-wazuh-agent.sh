#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR, PKG_FMT, WAZUH_REPO_FLAVOR (from detect.sh)
#           WAZUH_* variables exported (from vars.sh)

_WAZUH_GPG_URL="https://packages.wazuh.com/key/GPG-KEY-WAZUH"

# Derives the major version for the repo URL (e.g. "4.9.1" -> "4", empty -> "4").
_wazuh_repo_major() {
    if [[ -n "${WAZUH_VERSION:-}" ]]; then
        echo "${WAZUH_VERSION%%.*}"
    else
        echo "4"
    fi
}

# Builds the package name with optional version pin.
# deb: wazuh-agent=4.9.1-1  rpm: wazuh-agent-4.9.1-1  latest: wazuh-agent
_wazuh_pkg_name() {
    if [[ "${PKG_FMT}" == "deb" ]]; then
        echo "wazuh-agent${WAZUH_VERSION:+=${WAZUH_VERSION}-1}"
    else
        echo "wazuh-agent${WAZUH_VERSION:+-${WAZUH_VERSION}-1}"
    fi
}

_wazuh_is_installed() {
    case "${PKG_FMT}" in
        deb) dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null \
                | grep -q "install ok installed" ;;
        rpm) rpm -q wazuh-agent >/dev/null 2>&1 ;;
    esac
}

_wazuh_add_repo() {
    local major repo_base
    major="$(_wazuh_repo_major)"
    repo_base="https://packages.wazuh.com/${major}.x"

    case "${WAZUH_REPO_FLAVOR}" in
        debian)
            info "Adding Wazuh apt repository (${repo_base}/apt/) ..."
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                info "  Downloading GPG key from ${_WAZUH_GPG_URL} ..."
                curl -fsSL --connect-timeout 10 --max-time 30 "${_WAZUH_GPG_URL}" \
                    | gpg --dearmor \
                    | tee /usr/share/keyrings/wazuh.gpg >/dev/null
                chmod 644 /usr/share/keyrings/wazuh.gpg
                ok "  GPG key installed at /usr/share/keyrings/wazuh.gpg"

                info "  Writing repo list entry to /etc/apt/sources.list.d/wazuh.list ..."
                echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] ${repo_base}/apt/ stable main" \
                    > /etc/apt/sources.list.d/wazuh.list
                ok "  Repo file written"

                info "  Running apt-get update (this may take a moment) ..."
                apt-get update -q
                ok "  apt-get update complete"
            else
                warn "[DRY-RUN] Would add Wazuh GPG key and apt repo at ${repo_base}/apt/"
            fi
            ;;
        redhat)
            info "Adding Wazuh yum/dnf repository (${repo_base}/yum/) ..."
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                info "  Importing GPG key ..."
                rpm --import "${_WAZUH_GPG_URL}"
                ok "  GPG key imported"

                info "  Writing /etc/yum.repos.d/wazuh.repo ..."
                cat > /etc/yum.repos.d/wazuh.repo <<REPO
[wazuh]
gpgcheck=1
gpgkey=${_WAZUH_GPG_URL}
enabled=1
name=Wazuh repository
baseurl=${repo_base}/yum/
protect=1
REPO
                ok "  Repo file written"
            else
                warn "[DRY-RUN] Would add Wazuh GPG key and yum repo at ${repo_base}/yum/"
            fi
            ;;
        suse)
            info "Adding Wazuh zypper repository (${repo_base}/yum/) ..."
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                info "  Importing GPG key ..."
                rpm --import "${_WAZUH_GPG_URL}"
                ok "  GPG key imported"

                info "  Adding zypper repo ..."
                zypper addrepo --no-gpgcheck "${repo_base}/yum/" wazuh 2>/dev/null || true
                zypper --gpg-auto-import-keys refresh wazuh
                ok "  Repo added"
            else
                warn "[DRY-RUN] Would add Wazuh GPG key and zypper repo at ${repo_base}/yum/"
            fi
            ;;
    esac
}

install_wazuh_agent() {
    section "Wazuh Agent"

    if [[ -n "${PACKAGE_PATH:-}" ]]; then
        info "Installing from local package: ${PACKAGE_PATH}"
        case "${PKG_FMT}" in
            deb) run dpkg -i "${PACKAGE_PATH}" ;;
            rpm) run rpm -ihv "${PACKAGE_PATH}" ;;
        esac
    else
        if _wazuh_is_installed; then
            ok "wazuh-agent already installed — skipping package install"
        else
            _wazuh_add_repo
            local pkg
            pkg="$(_wazuh_pkg_name)"
            info "Installing ${pkg} ..."
            case "${PKG_MGR}" in
                apt-get) run apt-get install -y "${pkg}" ;;
                dnf)     run dnf     install -y "${pkg}" ;;
                yum)     run yum     install -y "${pkg}" ;;
                zypper)  run zypper  install -y "${pkg}" ;;
            esac
            ok "Package installed"
        fi
    fi

    info "Reloading systemd ..."
    run systemctl daemon-reload
    info "Enabling wazuh-agent service ..."
    run systemctl enable wazuh-agent
    info "Starting wazuh-agent service ..."
    run systemctl start  wazuh-agent

    ok "Wazuh agent installed and started"
}

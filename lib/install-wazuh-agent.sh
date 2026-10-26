#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR, PKG_FMT, WAZUH_REPO_FLAVOR (from detect.sh)
#           WAZUH_* variables exported (from vars.sh)

_WAZUH_GPG_URL="https://packages.wazuh.com/key/GPG-KEY-WAZUH"
_WAZUH_KEYRING="/usr/share/keyrings/wazuh.gpg"
_OSSEC_CONF="/var/ossec/etc/ossec.conf"

# Delimits the block appended to ossec.conf so uninstall can remove just that.
_LAUREL_LF_BEGIN="<!-- BEGIN wazuh-auditd-installer: LAUREL -->"
_LAUREL_LF_END="<!-- END wazuh-auditd-installer: LAUREL -->"

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

# A minimal Debian/Ubuntu image has neither gnupg nor curl, and the GPG
# pipeline below then fails obscurely.
_wazuh_install_repo_prereqs() {
    case "${PKG_MGR}" in
        apt-get)
            info "  Installing repository prerequisites (curl, gnupg, ca-certificates) ..."
            run apt-get update -q
            _APT_UPDATED=true
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl gnupg ca-certificates apt-transport-https
            ;;
        *)
            command -v curl >/dev/null 2>&1 \
                || die "curl is required to set up the Wazuh repository — install it first."
            ;;
    esac
}

_wazuh_add_repo() {
    local major repo_base
    major="$(_wazuh_repo_major)"
    repo_base="https://packages.wazuh.com/${major}.x"

    _wazuh_install_repo_prereqs

    case "${WAZUH_REPO_FLAVOR}" in
        debian)
            info "Adding Wazuh apt repository (${repo_base}/apt/) ..."
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                info "  Downloading GPG key from ${_WAZUH_GPG_URL} ..."
                install -d -m 0755 "$(dirname "${_WAZUH_KEYRING}")"
                curl -fsSL --connect-timeout 10 --max-time 30 "${_WAZUH_GPG_URL}" \
                    | gpg --dearmor \
                    | tee "${_WAZUH_KEYRING}" >/dev/null
                chmod 644 "${_WAZUH_KEYRING}"
                ok "  GPG key installed at ${_WAZUH_KEYRING}"
                info "  Key fingerprint:"
                gpg --show-keys --with-fingerprint "${_WAZUH_KEYRING}" 2>/dev/null \
                    | sed 's/^/    /' || true
                warn "  Verify this fingerprint against https://documentation.wazuh.com"

                info "  Writing repo list entry to /etc/apt/sources.list.d/wazuh.list ..."
                echo "deb [signed-by=${_WAZUH_KEYRING}] ${repo_base}/apt/ stable main" \
                    > /etc/apt/sources.list.d/wazuh.list
                ok "  Repo file written"

                info "  Running apt-get update (this may take a moment) ..."
                apt-get update -q
                _APT_UPDATED=true
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
                # gpgcheck stays ON. --no-gpgcheck / --gpg-auto-import-keys
                # accepted unsigned packages, unlike the apt and yum paths.
                info "  Importing GPG key ..."
                rpm --import "${_WAZUH_GPG_URL}"
                ok "  GPG key imported"

                if zypper --non-interactive lr wazuh >/dev/null 2>&1; then
                    info "  Repo 'wazuh' already present — refreshing ..."
                else
                    info "  Adding zypper repo (gpgcheck enabled) ..."
                    zypper --non-interactive addrepo --refresh --gpgcheck \
                        "${repo_base}/yum/" wazuh
                fi
                zypper --non-interactive refresh wazuh
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
            deb)
                run dpkg -i "${PACKAGE_PATH}"
                run_ok apt-get install -y -f   # dpkg -i resolves no dependencies
                ;;
            rpm) run rpm -ihv "${PACKAGE_PATH}" ;;
        esac
    else
        if _wazuh_is_installed; then
            ok "wazuh-agent already installed — skipping package install"
            # The WAZUH_* vars are read by the package post-install script,
            # which does not run again here.
            warn "Deployment variables (--manager, --agent-group, ...) are applied by the"
            warn "package post-install script and are NOT re-applied to an existing install."
            warn "Edit ${_OSSEC_CONF} by hand, or purge the agent first, to change them."
            [[ -z "${WAZUH_VERSION:-}" ]] \
                || warn "--wazuh-version ${WAZUH_VERSION} ignored: agent already installed."
        else
            _wazuh_add_repo
            local pkg
            pkg="$(_wazuh_pkg_name)"
            info "Installing ${pkg} ..."
            case "${PKG_MGR}" in
                apt-get) run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" ;;
                dnf)     run dnf     install -y "${pkg}" ;;
                yum)     run yum     install -y "${pkg}" ;;
                zypper)  run zypper --non-interactive install -y "${pkg}" ;;
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

# Adds the <localfile> entry that forwards LAUREL's output. Without it the
# pipeline is inert: LAUREL writes JSON that nothing reads. Idempotent.
configure_laurel_localfile() {
    section "Agent log collection (LAUREL)"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        ok "[DRY-RUN] Would add a <localfile> entry for /var/log/laurel/audit.log to ${_OSSEC_CONF}"
        return 0
    fi

    if [[ ! -f "${_OSSEC_CONF}" ]]; then
        warn "${_OSSEC_CONF} not found — add the LAUREL <localfile> entry manually:"
        warn "  <localfile><log_format>json</log_format><location>/var/log/laurel/audit.log</location></localfile>"
        return 0
    fi

    if grep -q "/var/log/laurel/audit.log" "${_OSSEC_CONF}"; then
        ok "LAUREL log already configured for collection"
        return 0
    fi

    info "Backing up ${_OSSEC_CONF} ..."
    cp -a "${_OSSEC_CONF}" "${_OSSEC_CONF}.bak.$(date +%s)"

    # ossec.conf accepts several top-level <ossec_config> sections, so
    # appending one beats editing inside the existing block.
    info "Adding <localfile> entry for /var/log/laurel/audit.log ..."
    cat >> "${_OSSEC_CONF}" <<CONF

${_LAUREL_LF_BEGIN}
<ossec_config>
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/laurel/audit.log</location>
  </localfile>
</ossec_config>
${_LAUREL_LF_END}
CONF
    ok "Entry added"

    info "Restarting wazuh-agent to pick up the new log source ..."
    if systemctl restart wazuh-agent; then
        ok "wazuh-agent restarted"
    else
        warn "wazuh-agent restart failed — check: journalctl -u wazuh-agent"
    fi
}

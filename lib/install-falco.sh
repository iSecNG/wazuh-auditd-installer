#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR, PKG_FMT, WAZUH_REPO_FLAVOR (from detect.sh)
#           REPO_DIR (from install.sh), run/ok/warn/die (from common.sh)

_FALCO_GPG_URL="https://falco.org/repo/falcosecurity-packages.asc"
_FALCO_KEYRING="/usr/share/keyrings/falco-archive-keyring.gpg"
_FALCO_RPM_REPO_URL="https://falco.org/repo/falcosecurity-rpm.repo"
_FALCO_APT_LIST="/etc/apt/sources.list.d/falcosecurity.list"
_FALCO_RULES_DST="/etc/falco/rules.d/wazuh-falco-rules.yaml"
# zz- prefix: /etc/falco/config.d is merged in filename order, and falcoctl
# writes its own engine-kind-falcoctl.yaml there. Sorting last means our
# output settings are not silently overridden.
_FALCO_CONF_DST="/etc/falco/config.d/zz-wazuh.yaml"
_FALCO_LOGROTATE_DST="/etc/logrotate.d/falco-wazuh"
_FALCO_LOG="/var/log/falco/events.json"

# Set by _falco_pick_driver(): the unit name the package will enable.
_FALCO_UNIT=""
_FALCO_DRIVER=""

_falco_is_installed() {
    case "${PKG_FMT}" in
        deb) dpkg-query -W -f='${Status}' falco 2>/dev/null \
                | grep -q "install ok installed" ;;
        rpm) rpm -q falco >/dev/null 2>&1 ;;
    esac
}

# modern_ebpf is CO-RE: one binary-embedded probe, no compiler and no kernel
# headers on the host. It needs a kernel with BTF, which means >= 5.8 built
# with CONFIG_DEBUG_INFO_BTF. Without that the only remaining option is the
# kernel module, which is compiled via DKMS at install time.
_falco_pick_driver() {
    local kver major minor
    kver="$(uname -r)"
    major="${kver%%.*}"
    minor="${kver#*.}"; minor="${minor%%.*}"

    if [[ -f /sys/kernel/btf/vmlinux ]] \
        && { (( major > 5 )) || { (( major == 5 )) && (( minor >= 8 )); }; }; then
        _FALCO_DRIVER="modern_ebpf"
        _FALCO_UNIT="falco-modern-bpf.service"
        ok "Driver: modern_ebpf  (kernel ${kver}, BTF present)"
        return 0
    fi

    _FALCO_DRIVER="kmod"
    _FALCO_UNIT="falco-kmod.service"
    warn "Kernel ${kver} has no usable BTF (/sys/kernel/btf/vmlinux missing or kernel < 5.8)."
    warn "Falling back to the 'kmod' driver, which DKMS-compiles a kernel module"
    warn "at install time and again on every kernel update. It needs a compiler"
    warn "and the matching kernel headers to be present."
    warn "Use --skip-falco if that is not acceptable on this host."
}

_falco_add_repo() {
    case "${WAZUH_REPO_FLAVOR}" in
        debian)
            info "Adding Falco apt repository ..."
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                # A minimal image has neither curl nor gnupg, and the pipeline
                # below then fails obscurely. The Wazuh step usually installed
                # these already, but --skip-* ordering must not be relied on.
                run apt-get update -q
                _APT_UPDATED=true
                run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    curl gnupg ca-certificates apt-transport-https

                info "  Downloading GPG key from ${_FALCO_GPG_URL} ..."
                install -d -m 0755 "$(dirname "${_FALCO_KEYRING}")"
                curl -fsSL --connect-timeout 10 --max-time 30 "${_FALCO_GPG_URL}" \
                    | gpg --dearmor \
                    | tee "${_FALCO_KEYRING}" >/dev/null
                chmod 644 "${_FALCO_KEYRING}"
                ok "  GPG key installed at ${_FALCO_KEYRING}"
                info "  Key fingerprint:"
                gpg --show-keys --with-fingerprint "${_FALCO_KEYRING}" 2>/dev/null \
                    | sed 's/^/    /' || true
                warn "  Verify this fingerprint against https://falco.org/docs/"

                echo "deb [signed-by=${_FALCO_KEYRING}] https://download.falco.org/packages/deb stable main" \
                    > "${_FALCO_APT_LIST}"
                ok "  Repo file written to ${_FALCO_APT_LIST}"

                info "  Running apt-get update ..."
                apt-get update -q
                ok "  apt-get update complete"
            else
                warn "[DRY-RUN] Would add Falco GPG key and apt repo"
            fi
            ;;
        redhat|suse)
            local repo_dst="/etc/yum.repos.d/falcosecurity.repo"
            [[ "${WAZUH_REPO_FLAVOR}" == "suse" ]] \
                && repo_dst="/etc/zypp/repos.d/falcosecurity.repo"

            info "Adding Falco rpm repository (${repo_dst}) ..."
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                command -v curl >/dev/null 2>&1 \
                    || die "curl is required to set up the Falco repository — install it first."
                info "  Importing GPG key ..."
                rpm --import "${_FALCO_GPG_URL}"
                ok "  GPG key imported"
                # Fetch the project's own .repo file rather than hand-writing a
                # stanza, so baseurl and gpg settings stay whatever upstream ships.
                info "  Fetching repo definition from ${_FALCO_RPM_REPO_URL} ..."
                curl -fsSL --connect-timeout 10 --max-time 30 \
                    -o "${repo_dst}" "${_FALCO_RPM_REPO_URL}" \
                    || die "Could not download ${_FALCO_RPM_REPO_URL}"
                chmod 644 "${repo_dst}"
                ok "  Repo file written"
                if [[ "${WAZUH_REPO_FLAVOR}" == "suse" ]]; then
                    run_ok zypper --non-interactive refresh falcosecurity-rpm
                fi
            else
                warn "[DRY-RUN] Would add Falco GPG key and rpm repo at ${repo_dst}"
            fi
            ;;
    esac
}

# Deploys this repo's ruleset, output config and logrotate rule. Split out of
# install_falco so a config-only change can be re-applied by re-running the
# installer over an existing Falco.
_falco_deploy_config() {
    local rules_src="${REPO_DIR}/falco/rules/wazuh-falco-rules.yaml"
    local conf_src="${REPO_DIR}/falco/falco-local.yaml"
    local lr_src="${REPO_DIR}/falco/logrotate-falco-wazuh"

    [[ -f "${rules_src}" ]] || die "Falco ruleset not found at ${rules_src}"
    [[ -f "${conf_src}"  ]] || die "Falco config not found at ${conf_src}"

    # Falco writes events.json as root; 0750 keeps the contents away from other
    # local users, since the alerts name paths and command lines.
    run install -d -m 0750 "$(dirname "${_FALCO_LOG}")"

    info "Deploying ruleset to ${_FALCO_RULES_DST} ..."
    run install -d -m 0755 "$(dirname "${_FALCO_RULES_DST}")"
    run install -m 0640 "${rules_src}" "${_FALCO_RULES_DST}"

    info "Deploying output config to ${_FALCO_CONF_DST} ..."
    run install -d -m 0755 "$(dirname "${_FALCO_CONF_DST}")"
    run install -m 0640 "${conf_src}" "${_FALCO_CONF_DST}"

    if [[ -f "${lr_src}" ]]; then
        info "Deploying logrotate rule to ${_FALCO_LOGROTATE_DST} ..."
        run install -m 0644 "${lr_src}" "${_FALCO_LOGROTATE_DST}"
    fi

    # Validate before restarting: a bad ruleset otherwise takes Falco down and
    # the host loses detection entirely. The explicit -c is required — without
    # it `falco --validate` reads a default config path and fails on the
    # config.d drop-in with "Error: bad file" even when the rules are fine.
    if [[ "${DRY_RUN:-false}" != "true" ]] && command -v falco >/dev/null 2>&1; then
        info "Validating ruleset ..."
        if falco -c /etc/falco/falco.yaml --validate "${_FALCO_RULES_DST}" 2>&1 \
            | grep -q '"successful":true'; then
            ok "Ruleset valid"
        else
            warn "Ruleset validation did not report success — inspect with:"
            warn "  falco -c /etc/falco/falco.yaml --validate ${_FALCO_RULES_DST}"
        fi
    fi
}

install_falco() {
    section "Falco"

    _falco_pick_driver

    if _falco_is_installed; then
        ok "falco already installed — skipping package install"
    else
        _falco_add_repo
        info "Installing falco (driver: ${_FALCO_DRIVER}) ..."
        # The package's postinst does the driver work itself when these are set:
        #   FALCO_FRONTEND=noninteractive  never show the dialog(1) menu
        #   FALCO_DRIVER_CHOICE=<driver>   configure falcoctl, enable+start the unit
        #   FALCOCTL_ENABLED=no            mask falcoctl-artifact-follow, pinning
        #                                  the ruleset instead of auto-updating it
        # Without FALCO_DRIVER_CHOICE the postinst defaults to "auto", which
        # enables whichever driver falcoctl picks — not reproducible across hosts.
        local -a env_vars=(
            FALCO_FRONTEND=noninteractive
            FALCO_DRIVER_CHOICE="${_FALCO_DRIVER}"
            FALCOCTL_ENABLED=no
        )
        case "${PKG_MGR}" in
            apt-get) run env DEBIAN_FRONTEND=noninteractive "${env_vars[@]}" \
                         apt-get install -y falco ;;
            dnf)     run env "${env_vars[@]}" dnf    install -y falco ;;
            yum)     run env "${env_vars[@]}" yum    install -y falco ;;
            zypper)  run env "${env_vars[@]}" zypper --non-interactive install -y falco ;;
        esac
        ok "Package installed"
    fi

    _falco_deploy_config

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        run systemctl enable "${_FALCO_UNIT}"
        run systemctl restart "${_FALCO_UNIT}"
        ok "[DRY-RUN] Falco would be configured and ${_FALCO_UNIT} started"
        return 0
    fi

    # The postinst already enabled and started the chosen unit, but it did so
    # before our ruleset and output config were in place. Restart to pick them
    # up, and enable defensively in case Falco was already installed by hand.
    run_ok systemctl enable "${_FALCO_UNIT}"
    info "Restarting ${_FALCO_UNIT} to load the ruleset ..."
    if ! systemctl restart "${_FALCO_UNIT}"; then
        warn "${_FALCO_UNIT} failed to start — check: journalctl -u ${_FALCO_UNIT}"
        return 0
    fi

    nap 3
    if systemctl is-active --quiet "${_FALCO_UNIT}"; then
        ok "falco running  (${_FALCO_UNIT}, driver ${_FALCO_DRIVER})"
    else
        warn "${_FALCO_UNIT} is not active — check: journalctl -u ${_FALCO_UNIT}"
    fi

    # falcoctl-artifact-follow would replace falco_rules.yaml underneath us on
    # its own schedule. FALCOCTL_ENABLED=no makes the postinst mask it; confirm,
    # because an earlier manual install may have left it running.
    if systemctl is-active --quiet falcoctl-artifact-follow.service 2>/dev/null; then
        warn "falcoctl-artifact-follow is running: the upstream ruleset will be"
        warn "auto-updated, so detections can change without a deployment."
        warn "Pin it with: systemctl mask --now falcoctl-artifact-follow.service"
    else
        ok "falcoctl auto-update disabled — ruleset is pinned to the package"
    fi
}

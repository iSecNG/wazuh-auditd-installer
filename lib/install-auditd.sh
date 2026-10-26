#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR (from detect.sh), REPO_DIR (from install.sh)

# 99- prefix: augenrules concatenates rules.d in filename order, so our "-D"
# and -b/-f settings must load last. Also leaves the distro's audit.rules alone.
AUDITD_RULES_DST="/etc/audit/rules.d/99-wazuh.rules"

install_auditd() {
    section "auditd"

    if command -v auditctl >/dev/null 2>&1; then
        ok "auditd already installed"
    else
        info "Installing auditd ..."
        case "${PKG_MGR}" in
            apt-get)
                [[ "${_APT_UPDATED:-false}" == "true" ]] || run apt-get update -q
                run apt-get install -y auditd audispd-plugins
                ;;
            dnf)    run dnf    install -y audit ;;
            yum)    run yum    install -y audit ;;
            zypper) run zypper install -y audit ;;
        esac
    fi

    local rules_src="${REPO_DIR}/auditd/rules/audit.rules"
    [[ -f "${rules_src}" ]] || die "audit.rules not found at ${rules_src}"

    # Back up a previous deployment, but only when it actually differs, so that
    # re-running the installer does not pile up identical backups.
    if [[ -f "${AUDITD_RULES_DST}" ]] && ! cmp -s "${rules_src}" "${AUDITD_RULES_DST}"; then
        info "Backing up existing ${AUDITD_RULES_DST} ..."
        run cp -a "${AUDITD_RULES_DST}" "${AUDITD_RULES_DST}.bak.$(date +%s)"
    fi

    info "Deploying audit rules to ${AUDITD_RULES_DST} ..."
    run install -m 0640 "${rules_src}" "${AUDITD_RULES_DST}"

    run systemctl enable auditd

    # Do not restart auditd: the RHEL-family unit sets RefuseManualStop=yes, so
    # `systemctl restart auditd` fails and aborts the installer. augenrules
    # --load applies a changed ruleset everywhere without a restart.
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        run systemctl start auditd
        run augenrules --load
        ok "[DRY-RUN] auditd would be configured and the ruleset loaded"
        return 0
    fi

    systemctl is-active --quiet auditd || run systemctl start auditd
    info "Loading ruleset with augenrules --load ..."
    if ! augenrules --load; then
        warn "augenrules --load reported errors — some rules may not have loaded"
        warn "Inspect with: augenrules --check ; auditctl -l"
    fi

    nap 1
    local rule_count
    rule_count=$(auditctl -l 2>/dev/null | grep -cvE '^(No rules|$)' || true)
    if (( rule_count > 0 )); then
        ok "auditd running with ${rule_count} rules loaded"
    else
        warn "auditd reports no loaded rules — check: auditctl -s ; augenrules --check"
    fi
}

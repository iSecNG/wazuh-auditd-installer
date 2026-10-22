#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR (from detect.sh), REPO_DIR (from install.sh)

install_auditd() {
    section "auditd"

    if command -v auditctl >/dev/null 2>&1; then
        ok "auditd already installed"
    else
        info "Installing auditd ..."
        case "${PKG_MGR}" in
            apt-get) run apt-get install -y auditd audispd-plugins ;;
            dnf)     run dnf     install -y audit ;;
            yum)     run yum     install -y audit ;;
            zypper)  run zypper  install -y audit ;;
        esac
    fi

    local rules_src="${REPO_DIR}/auditd/rules/audit.rules"
    [[ -f "${rules_src}" ]] || die "audit.rules not found at ${rules_src}"

    info "Deploying audit rules to /etc/audit/rules.d/audit.rules ..."
    run cp    "${rules_src}" /etc/audit/rules.d/audit.rules
    run chmod 640 /etc/audit/rules.d/audit.rules

    run systemctl enable auditd
    run systemctl restart auditd

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        sleep 1
        local rule_count
        rule_count=$(auditctl -l 2>/dev/null | wc -l)
        ok "auditd running with ${rule_count} rules loaded"
    else
        ok "[DRY-RUN] auditd would be configured and restarted"
    fi
}

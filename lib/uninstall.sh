#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR, PKG_FMT, WAZUH_REPO_FLAVOR (from detect.sh)

uninstall_wazuh_agent() {
    section "Uninstall: Wazuh Agent"

    # Stop and disable service before package removal
    if systemctl is-active --quiet wazuh-agent 2>/dev/null; then
        info "Stopping wazuh-agent service ..."
        run systemctl stop wazuh-agent
    fi
    if systemctl is-enabled --quiet wazuh-agent 2>/dev/null; then
        run systemctl disable wazuh-agent
    fi

    case "${PKG_FMT}" in
        deb)
            if dpkg-query -W wazuh-agent >/dev/null 2>&1; then
                info "Removing wazuh-agent package ..."
                run apt-get purge -y wazuh-agent
                ok "Package removed"
            else
                ok "wazuh-agent not installed — skipping"
            fi
            if [[ -f /etc/apt/sources.list.d/wazuh.list ]]; then
                info "Removing Wazuh apt repo and GPG key ..."
                run rm -f /etc/apt/sources.list.d/wazuh.list
                run rm -f /usr/share/keyrings/wazuh.gpg
                info "Running apt-get update ..."
                run apt-get update -q
                ok "Apt repo removed"
            fi
            ;;
        rpm)
            if rpm -q wazuh-agent >/dev/null 2>&1; then
                info "Removing wazuh-agent package ..."
                case "${PKG_MGR}" in
                    dnf)    run dnf    remove -y wazuh-agent ;;
                    yum)    run yum    remove -y wazuh-agent ;;
                    zypper) run zypper remove -y wazuh-agent ;;
                esac
                ok "Package removed"
            else
                ok "wazuh-agent not installed — skipping"
            fi
            if [[ -f /etc/yum.repos.d/wazuh.repo ]]; then
                info "Removing Wazuh yum repo ..."
                run rm -f /etc/yum.repos.d/wazuh.repo
                ok "Yum repo removed"
            fi
            ;;
    esac
}

uninstall_auditd() {
    section "Uninstall: auditd rules"

    if [[ -f /etc/audit/rules.d/audit.rules ]]; then
        info "Removing Wazuh auditd ruleset ..."
        run rm -f /etc/audit/rules.d/audit.rules
        ok "Rules file removed"
    else
        ok "/etc/audit/rules.d/audit.rules not found — nothing to remove"
    fi

    if systemctl is-active --quiet auditd 2>/dev/null; then
        info "Restarting auditd to clear loaded rules ..."
        run systemctl restart auditd
        ok "auditd restarted"
    fi
}

uninstall_laurel() {
    section "Uninstall: LAUREL"

    # Detect the plugin directory used at install time
    local plugin_dir auditd_major
    auditd_major=$(auditctl -v 2>/dev/null | grep -oP '\d+' | head -1 || echo "3")
    if (( auditd_major >= 3 )); then
        plugin_dir="/etc/audit/plugins.d"
    else
        plugin_dir="/etc/audisp/plugins.d"
    fi

    # Remove auditd plugin config first so auditd stops spawning LAUREL on reload
    if [[ -f "${plugin_dir}/laurel.conf" ]]; then
        info "Removing LAUREL auditd plugin config ..."
        run rm -f "${plugin_dir}/laurel.conf"
        ok "Plugin config removed from ${plugin_dir}"
    fi

    # Signal auditd to reload so it stops the LAUREL process
    if systemctl is-active --quiet auditd 2>/dev/null; then
        info "Signalling auditd to reload (will stop LAUREL process) ..."
        run pkill -HUP auditd
        sleep 2
    fi

    # If LAUREL is still running after the reload, kill it directly
    if pgrep -x laurel >/dev/null 2>&1; then
        info "Stopping LAUREL process ..."
        run pkill -x laurel
        sleep 1
    fi

    if [[ -f /usr/local/sbin/laurel ]]; then
        info "Removing LAUREL binary ..."
        run rm -f /usr/local/sbin/laurel
        ok "Binary removed"
    else
        ok "/usr/local/sbin/laurel not found — skipping"
    fi

    if [[ -d /etc/laurel ]]; then
        info "Removing LAUREL config directory (/etc/laurel) ..."
        run rm -rf /etc/laurel
        ok "Config removed"
    fi

    if id "_laurel" >/dev/null 2>&1; then
        info "Removing system user '_laurel' ..."
        run userdel _laurel
        ok "User removed"
    fi

    ok "LAUREL uninstalled"

    # Preserve logs — they may contain forensic data
    if [[ -d /var/log/laurel ]]; then
        warn "Log directory preserved at /var/log/laurel"
        warn "Remove manually if no longer needed: rm -rf /var/log/laurel"
    fi
}

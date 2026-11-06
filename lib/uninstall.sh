#!/usr/bin/env bash
# Source this file; do not execute directly.
# Requires: PKG_MGR, PKG_FMT, WAZUH_REPO_FLAVOR (from detect.sh)
#           AUDITD_RULES_DST (from install-auditd.sh)
#           _OSSEC_CONF, _LAUREL_LF_*_RE, _FALCO_LF_*_RE (from install-wazuh-agent.sh)
#           _FALCO_* paths (from install-falco.sh)

# Marker line in every ruleset we deploy, to tell ours apart from a
# distro-provided /etc/audit/rules.d/audit.rules. An ERE, not a literal: rulesets
# deployed before the wazuh-auditd-installer -> wazuh-linux-sensors rename carry
# the old name and must still be recognised as ours.
_AUDITD_RULES_MARKER_RE="# wazuh-(auditd-installer|linux-sensors): managed ruleset"

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
            if dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null \
                | grep -q "install ok installed"; then
                info "Removing wazuh-agent package ..."
                run env DEBIAN_FRONTEND=noninteractive apt-get purge -y wazuh-agent
                ok "Package removed"
            else
                ok "wazuh-agent not installed — skipping"
            fi
            if [[ -f /etc/apt/sources.list.d/wazuh.list ]]; then
                info "Removing Wazuh apt repo and GPG key ..."
                run rm -f /etc/apt/sources.list.d/wazuh.list
                run rm -f /usr/share/keyrings/wazuh.gpg
                info "Running apt-get update ..."
                run_ok apt-get update -q
                ok "Apt repo removed"
            fi
            ;;
        rpm)
            if rpm -q wazuh-agent >/dev/null 2>&1; then
                info "Removing wazuh-agent package ..."
                case "${PKG_MGR}" in
                    dnf)    run dnf    remove -y wazuh-agent ;;
                    yum)    run yum    remove -y wazuh-agent ;;
                    zypper) run zypper --non-interactive remove -y wazuh-agent ;;
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
            if [[ "${WAZUH_REPO_FLAVOR}" == "suse" ]]; then
                zypper --non-interactive lr wazuh >/dev/null 2>&1 \
                    && { info "Removing Wazuh zypper repo ..."
                         run zypper --non-interactive removerepo wazuh
                         ok "Zypper repo removed"; }
            fi
            ;;
    esac
}

uninstall_auditd() {
    section "Uninstall: auditd rules"

    local removed=false

    if [[ -f "${AUDITD_RULES_DST}" ]]; then
        info "Removing ${AUDITD_RULES_DST} ..."
        run rm -f "${AUDITD_RULES_DST}"
        removed=true
        ok "Rules file removed"
    fi

    # Older versions wrote to rules.d/audit.rules, which several distros also
    # ship. Only remove it when it carries our marker.
    local legacy="/etc/audit/rules.d/audit.rules"
    if [[ -f "${legacy}" ]]; then
        if grep -qE "${_AUDITD_RULES_MARKER_RE}" "${legacy}" 2>/dev/null; then
            info "Removing legacy ruleset at ${legacy} ..."
            run rm -f "${legacy}"
            removed=true
            ok "Legacy rules file removed"
        else
            info "${legacy} is not managed by this installer — left in place"
        fi
    fi

    [[ "${removed}" == "true" ]] || ok "No managed ruleset found — nothing to remove"

    # Reload, do not restart: the RHEL-family unit sets RefuseManualStop=yes.
    if systemctl is-active --quiet auditd 2>/dev/null; then
        info "Reloading remaining audit rules (augenrules --load) ..."
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            run augenrules --load
        elif augenrules --load; then
            ok "Rules reloaded"
        else
            warn "augenrules --load reported errors — check: auditctl -l"
        fi
    fi
}

uninstall_laurel() {
    section "Uninstall: LAUREL"

    # Detect the plugin directory used at install time
    local plugin_dir auditd_major
    auditd_major=$(auditctl -v 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "3")
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
        run_ok pkill -HUP auditd
        nap 2
    fi

    # If LAUREL is still running after the reload, kill it directly
    if pgrep -x laurel >/dev/null 2>&1; then
        info "Stopping LAUREL process ..."
        run_ok pkill -x laurel
        nap 1
    fi

    if [[ -f /usr/local/sbin/laurel ]]; then
        info "Removing LAUREL binary ..."
        run rm -f /usr/local/sbin/laurel
        ok "Binary removed"
    else
        ok "/usr/local/sbin/laurel not found — skipping"
    fi

    if command -v semodule >/dev/null 2>&1 && semodule -l 2>/dev/null | grep -x laurel >/dev/null; then
        info "Removing LAUREL SELinux module ..."
        run semodule -r laurel
        ok "SELinux module removed"
    fi

    if [[ -d /etc/laurel ]]; then
        info "Removing LAUREL config directory (/etc/laurel) ..."
        run rm -rf /etc/laurel
        ok "Config removed"
    fi

    if id "_laurel" >/dev/null 2>&1; then
        info "Removing system user '_laurel' ..."
        run_ok userdel _laurel
        ok "User removed"
    fi

    # Drop the <localfile> block we appended, if ossec.conf is still there.
    if [[ -f "${_OSSEC_CONF}" ]] \
        && grep -qE "${_LAUREL_LF_BEGIN_RE}" "${_OSSEC_CONF}" 2>/dev/null; then
        info "Removing LAUREL <localfile> entry from ${_OSSEC_CONF} ..."
        run cp -a "${_OSSEC_CONF}" "${_OSSEC_CONF}.bak.$(date +%s)"
        # The markers are XML comments, so # is safe as the sed address delimiter --
        # | is not, the pattern is an ERE and contains one.
        run sed -i -E "\\#${_LAUREL_LF_BEGIN_RE}#,\\#${_LAUREL_LF_END_RE}#d" "${_OSSEC_CONF}"
        ok "Entry removed"
    fi

    ok "LAUREL uninstalled"

    # Preserve logs — they may contain forensic data
    if [[ -d /var/log/laurel ]]; then
        warn "Log directory preserved at /var/log/laurel"
        warn "Remove manually if no longer needed: rm -rf /var/log/laurel"
    fi
}

uninstall_falco() {
    section "Uninstall: Falco"

    # Stop whichever driver unit is in use before removing the package. The
    # unit depends on the host's driver choice, so try all of them.
    local unit
    for unit in falco-modern-bpf.service falco-kmod.service falco-custom.service; do
        if systemctl is-active --quiet "${unit}" 2>/dev/null; then
            info "Stopping ${unit} ..."
            run systemctl stop "${unit}"
        fi
        if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
            run_ok systemctl disable "${unit}"
        fi
    done

    case "${PKG_FMT}" in
        deb)
            if dpkg-query -W -f='${Status}' falco 2>/dev/null \
                | grep -q "install ok installed"; then
                info "Removing falco package ..."
                run env DEBIAN_FRONTEND=noninteractive apt-get purge -y falco
                ok "Package removed"
            else
                ok "falco not installed — skipping"
            fi
            if [[ -f "${_FALCO_APT_LIST:-/etc/apt/sources.list.d/falcosecurity.list}" ]]; then
                info "Removing Falco apt repo and GPG key ..."
                run rm -f "${_FALCO_APT_LIST:-/etc/apt/sources.list.d/falcosecurity.list}"
                run rm -f "${_FALCO_KEYRING:-/usr/share/keyrings/falco-archive-keyring.gpg}"
                info "Running apt-get update ..."
                run_ok apt-get update -q
                ok "Apt repo removed"
            fi
            ;;
        rpm)
            if rpm -q falco >/dev/null 2>&1; then
                info "Removing falco package ..."
                case "${PKG_MGR}" in
                    dnf)    run dnf    remove -y falco ;;
                    yum)    run yum    remove -y falco ;;
                    zypper) run zypper --non-interactive remove -y falco ;;
                esac
                ok "Package removed"
            else
                ok "falco not installed — skipping"
            fi
            if [[ -f /etc/yum.repos.d/falcosecurity.repo ]]; then
                info "Removing Falco yum repo ..."
                run rm -f /etc/yum.repos.d/falcosecurity.repo
                ok "Yum repo removed"
            fi
            if [[ -f /etc/zypp/repos.d/falcosecurity.repo ]]; then
                info "Removing Falco zypper repo ..."
                run rm -f /etc/zypp/repos.d/falcosecurity.repo
                ok "Zypper repo removed"
            fi
            ;;
    esac

    # Our own files. A package purge does not touch rules.d/config.d drop-ins.
    local f
    for f in "${_FALCO_RULES_DST:-/etc/falco/rules.d/wazuh-falco-rules.yaml}" \
             "${_FALCO_CONF_DST:-/etc/falco/config.d/zz-wazuh.yaml}" \
             "${_FALCO_LOGROTATE_DST:-/etc/logrotate.d/falco-wazuh}"; do
        if [[ -f "${f}" ]]; then
            info "Removing ${f} ..."
            run rm -f "${f}"
        fi
    done

    # Unmask the auto-updater we masked at install time, so a later manual
    # Falco install behaves the way its own package intends.
    if [[ "$(readlink /etc/systemd/system/falcoctl-artifact-follow.service 2>/dev/null)" == "/dev/null" ]]; then
        info "Unmasking falcoctl-artifact-follow.service ..."
        run_ok systemctl unmask falcoctl-artifact-follow.service
    fi

    # Drop the <localfile> block we appended, if ossec.conf is still there.
    if [[ -f "${_OSSEC_CONF}" ]] \
        && grep -qE "${_FALCO_LF_BEGIN_RE}" "${_OSSEC_CONF}" 2>/dev/null; then
        info "Removing Falco <localfile> entry from ${_OSSEC_CONF} ..."
        run cp -a "${_OSSEC_CONF}" "${_OSSEC_CONF}.bak.$(date +%s)"
        run sed -i -E "\\#${_FALCO_LF_BEGIN_RE}#,\\#${_FALCO_LF_END_RE}#d" "${_OSSEC_CONF}"
        ok "Entry removed"
    fi

    ok "Falco uninstalled"

    # Preserve logs — they may contain forensic data, same as /var/log/laurel.
    if [[ -d /var/log/falco ]]; then
        warn "Log directory preserved at /var/log/falco"
        warn "Remove manually if no longer needed: rm -rf /var/log/falco"
    fi
}

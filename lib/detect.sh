#!/usr/bin/env bash
# Source this file; do not execute directly.
# Sets: DISTRO, DISTRO_VERSION, PKG_MGR, PKG_FMT, WAZUH_REPO_FLAVOR, ARCH

detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release not found — cannot detect OS."

    # shellcheck disable=SC1091
    source /etc/os-release

    DISTRO="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-0}"
    local distro_like="${ID_LIKE:-}"

    case "${DISTRO}" in
        ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)
            PKG_MGR="apt-get"; PKG_FMT="deb"; WAZUH_REPO_FLAVOR="debian"
            ;;
        rhel|centos|almalinux|rocky|ol|scientific)
            PKG_MGR="yum"; PKG_FMT="rpm"; WAZUH_REPO_FLAVOR="redhat"
            command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
            ;;
        fedora)
            PKG_MGR="dnf"; PKG_FMT="rpm"; WAZUH_REPO_FLAVOR="redhat"
            ;;
        amzn)
            PKG_MGR="yum"; PKG_FMT="rpm"; WAZUH_REPO_FLAVOR="redhat"
            command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
            ;;
        opensuse*|sles|sle-micro)
            PKG_MGR="zypper"; PKG_FMT="rpm"; WAZUH_REPO_FLAVOR="suse"
            ;;
        *)
            if   [[ "${distro_like}" == *"debian"* ]]; then
                PKG_MGR="apt-get"; PKG_FMT="deb"; WAZUH_REPO_FLAVOR="debian"
            elif [[ "${distro_like}" == *"rhel"* || "${distro_like}" == *"fedora"* ]]; then
                PKG_MGR="yum"; PKG_FMT="rpm"; WAZUH_REPO_FLAVOR="redhat"
                command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
            elif [[ "${distro_like}" == *"suse"* ]]; then
                PKG_MGR="zypper"; PKG_FMT="rpm"; WAZUH_REPO_FLAVOR="suse"
            else
                die "Unsupported distribution '${DISTRO}'. Supported: Ubuntu/Debian, RHEL/CentOS/AlmaLinux/Rocky, Fedora, Amazon Linux, openSUSE/SLES."
            fi
            ;;
    esac

    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)         ;;
        aarch64)        ;;
        armv7l) ARCH="armhf" ;;
        *) die "Unsupported architecture: ${ARCH}" ;;
    esac

    ok "Detected: ${DISTRO} ${DISTRO_VERSION} (${ARCH}) — package manager: ${PKG_MGR}"
    export DISTRO DISTRO_VERSION PKG_MGR PKG_FMT WAZUH_REPO_FLAVOR ARCH
}

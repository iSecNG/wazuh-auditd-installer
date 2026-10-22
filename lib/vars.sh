#!/usr/bin/env bash
# Source this file; do not execute directly.

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh --manager <address> [OPTIONS]
       sudo bash install.sh --uninstall [--skip-auditd] [--skip-laurel] [--dry-run]

Required (install only):
  --manager <addr>                    Wazuh manager IP or FQDN  (WAZUH_MANAGER)

Wazuh agent deployment variables:
  --manager-port <port>               WAZUH_MANAGER_PORT
  --protocol <tcp|udp>                WAZUH_PROTOCOL (default: TCP)
  --registration-server <addr>        WAZUH_REGISTRATION_SERVER (defaults to --manager)
  --registration-port <port>          WAZUH_REGISTRATION_PORT
  --registration-password <pass>      WAZUH_REGISTRATION_PASSWORD
  --keep-alive-interval <secs>        WAZUH_KEEP_ALIVE_INTERVAL
  --time-reconnect <secs>             WAZUH_TIME_RECONNECT
  --registration-ca <path>            WAZUH_REGISTRATION_CA
  --registration-certificate <path>   WAZUH_REGISTRATION_CERTIFICATE
  --registration-key <path>           WAZUH_REGISTRATION_KEY
  --agent-name <name>                 WAZUH_AGENT_NAME (default: hostname)
  --agent-group <groups>              WAZUH_AGENT_GROUP (comma-separated)
  --enrollment-delay <secs>           ENROLLMENT_DELAY

Install options:
  --wazuh-version <version>           Pin Wazuh agent version, e.g. 4.9.1 (default: latest)
  --package-path <path>               Install from local .deb/.rpm file (skips repo setup)
  --uninstall                         Remove Wazuh agent, auditd rules, and LAUREL
  --skip-auditd                       Skip auditd installation/removal and ruleset
  --skip-laurel                       Skip LAUREL installation/removal
  --dry-run                           Print actions without executing them
  --verbose                           Enable verbose output
  -h, --help                          Show this help

All --flags can be set as environment variables instead (e.g. WAZUH_MANAGER=10.0.0.1).
CLI flags take precedence over environment variables.
EOF
}

parse_args() {
    # Seed from environment; CLI flags override below.
    : "${WAZUH_MANAGER:=}"
    : "${WAZUH_MANAGER_PORT:=}"
    : "${WAZUH_PROTOCOL:=}"
    : "${WAZUH_REGISTRATION_SERVER:=}"
    : "${WAZUH_REGISTRATION_PORT:=}"
    : "${WAZUH_REGISTRATION_PASSWORD:=}"
    : "${WAZUH_KEEP_ALIVE_INTERVAL:=}"
    : "${WAZUH_TIME_RECONNECT:=}"
    : "${WAZUH_REGISTRATION_CA:=}"
    : "${WAZUH_REGISTRATION_CERTIFICATE:=}"
    : "${WAZUH_REGISTRATION_KEY:=}"
    : "${WAZUH_AGENT_NAME:=}"
    : "${WAZUH_AGENT_GROUP:=}"
    : "${ENROLLMENT_DELAY:=}"
    : "${WAZUH_VERSION:=}"
    : "${PACKAGE_PATH:=}"
    : "${SKIP_AUDITD:=false}"
    : "${SKIP_LAUREL:=false}"
    : "${UNINSTALL:=false}"
    : "${DRY_RUN:=false}"
    : "${VERBOSE:=false}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manager)                      WAZUH_MANAGER="$2";                  shift 2 ;;
            --manager-port)                 WAZUH_MANAGER_PORT="$2";             shift 2 ;;
            --protocol)                     WAZUH_PROTOCOL="$2";                 shift 2 ;;
            --registration-server)          WAZUH_REGISTRATION_SERVER="$2";      shift 2 ;;
            --registration-port)            WAZUH_REGISTRATION_PORT="$2";        shift 2 ;;
            --registration-password)        WAZUH_REGISTRATION_PASSWORD="$2";    shift 2 ;;
            --keep-alive-interval)          WAZUH_KEEP_ALIVE_INTERVAL="$2";      shift 2 ;;
            --time-reconnect)               WAZUH_TIME_RECONNECT="$2";           shift 2 ;;
            --registration-ca)              WAZUH_REGISTRATION_CA="$2";          shift 2 ;;
            --registration-certificate)     WAZUH_REGISTRATION_CERTIFICATE="$2"; shift 2 ;;
            --registration-key)             WAZUH_REGISTRATION_KEY="$2";         shift 2 ;;
            --agent-name)                   WAZUH_AGENT_NAME="$2";               shift 2 ;;
            --agent-group)                  WAZUH_AGENT_GROUP="$2";              shift 2 ;;
            --enrollment-delay)             ENROLLMENT_DELAY="$2";               shift 2 ;;
            --wazuh-version)                WAZUH_VERSION="$2";                  shift 2 ;;
            --package-path)                 PACKAGE_PATH="$2";                   shift 2 ;;
            --uninstall)                    UNINSTALL=true;                      shift   ;;
            --skip-auditd)                  SKIP_AUDITD=true;                    shift   ;;
            --skip-laurel)                  SKIP_LAUREL=true;                    shift   ;;
            --dry-run)                      DRY_RUN=true;                        shift   ;;
            --verbose)                      VERBOSE=true;                        shift   ;;
            -h|--help)                      usage; exit 0 ;;
            *) die "Unknown option: $1  (use --help for usage)" ;;
        esac
    done

    export DRY_RUN VERBOSE SKIP_AUDITD SKIP_LAUREL UNINSTALL
}

validate_vars() {
    # --manager is only required for installs, not for uninstall
    if [[ "${UNINSTALL:-false}" != "true" ]]; then
        [[ -n "${WAZUH_MANAGER}" ]] \
            || die "--manager is required (or set WAZUH_MANAGER)"
    fi

    if [[ -n "${WAZUH_PROTOCOL}" ]]; then
        local proto="${WAZUH_PROTOCOL^^}"
        [[ "${proto}" == "TCP" || "${proto}" == "UDP" ]] \
            || die "WAZUH_PROTOCOL must be TCP or UDP, got: ${WAZUH_PROTOCOL}"
        WAZUH_PROTOCOL="${proto}"
    fi

    local var val
    for var in WAZUH_REGISTRATION_CA WAZUH_REGISTRATION_CERTIFICATE WAZUH_REGISTRATION_KEY; do
        val="${!var}"
        [[ -z "${val}" || -f "${val}" ]] \
            || die "${var} path not found: ${val}"
    done

    [[ -z "${PACKAGE_PATH}" || -f "${PACKAGE_PATH}" ]] \
        || die "--package-path file not found: ${PACKAGE_PATH}"

    if [[ -n "${WAZUH_REGISTRATION_CERTIFICATE}" && -z "${WAZUH_REGISTRATION_KEY}" ]]; then
        warn "--registration-certificate given without --registration-key"
    fi
    if [[ -n "${WAZUH_REGISTRATION_KEY}" && -z "${WAZUH_REGISTRATION_CERTIFICATE}" ]]; then
        warn "--registration-key given without --registration-certificate"
    fi
}

# Export all non-empty WAZUH_* vars so the Wazuh package post-install script
# can read them to configure ossec.conf and run enrollment automatically.
export_wazuh_vars() {
    local vars=(
        WAZUH_MANAGER WAZUH_MANAGER_PORT WAZUH_PROTOCOL
        WAZUH_REGISTRATION_SERVER WAZUH_REGISTRATION_PORT WAZUH_REGISTRATION_PASSWORD
        WAZUH_KEEP_ALIVE_INTERVAL WAZUH_TIME_RECONNECT
        WAZUH_REGISTRATION_CA WAZUH_REGISTRATION_CERTIFICATE WAZUH_REGISTRATION_KEY
        WAZUH_AGENT_NAME WAZUH_AGENT_GROUP ENROLLMENT_DELAY
    )
    local var
    for var in "${vars[@]}"; do
        if [[ -n "${!var}" ]]; then
            export "${var?}"
        fi
    done
}

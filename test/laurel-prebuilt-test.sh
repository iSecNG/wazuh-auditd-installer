#!/usr/bin/env bash
# =============================================================================
# laurel-prebuilt-test.sh -- Check the prebuilt-vs-source decision and the pin
#
# Asserts that _laurel_prebuilt_blocker() routes each host to the right install
# path, and that the pinned sha256 still matches the release asset upstream
# serves. Installs nothing, needs no root.
#
# Usage:
#   bash test/laurel-prebuilt-test.sh           # decision logic only
#   bash test/laurel-prebuilt-test.sh --online  # also verify the pinned sha256
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLINE=false
[[ "${1:-}" == "--online" ]] && ONLINE=true

# Sourcing only defines functions: the standalone entrypoint is guarded.
# shellcheck source=../laurel/install-laurel.sh
source "${REPO_DIR}/laurel/install-laurel.sh"

FAILED=0
check() { # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        echo "[ OK ]  $1"
    else
        echo "[FAIL]  $1"
        echo "          expected: '$2'"
        echo "          actual  : '$3'"
        FAILED=$((FAILED + 1))
    fi
}

# Both functions read the architecture through uname, so override it per case.
uname() { if [[ "${1:-}" == "-m" ]]; then echo "${FAKE_ARCH}"; else command uname "$@"; fi; }

FAKE_ARCH=x86_64 LAUREL_BUILD_FROM_SOURCE=0
check "x86_64 at the pinned version uses the prebuilt binary" \
    "" "$(_laurel_prebuilt_blocker)"

FAKE_ARCH=aarch64
check "aarch64 builds from source (no static asset upstream)" \
    "no static release asset for aarch64" "$(_laurel_prebuilt_blocker)"

FAKE_ARCH=x86_64 LAUREL_BUILD_FROM_SOURCE=1
check "LAUREL_BUILD_FROM_SOURCE=1 overrides the prebuilt path" \
    "LAUREL_BUILD_FROM_SOURCE=1" "$(_laurel_prebuilt_blocker)"

# An unpinned version with no hash must not be downloaded: it cannot be verified.
LAUREL_BUILD_FROM_SOURCE=0 _LAUREL_VERSION="v9.9.9" _LAUREL_SHA256=""
check "an unverifiable version falls back to a source build" \
    "no known sha256 for v9.9.9 (set LAUREL_SHA256 to use the release tarball)" \
    "$(_laurel_prebuilt_blocker)"

check "an explicit LAUREL_SHA256 re-enables the prebuilt path" \
    "" "$(_LAUREL_SHA256=deadbeef _laurel_prebuilt_blocker)"

check "_laurel_prebuilt_sha prefers the explicit hash" \
    "deadbeef" "$(_LAUREL_SHA256=deadbeef _laurel_prebuilt_sha)"

_LAUREL_VERSION="${_LAUREL_PINNED_VERSION}" _LAUREL_SHA256=""
check "_laurel_prebuilt_sha falls back to the pin" \
    "${_LAUREL_PINNED_SHA256}" "$(_laurel_prebuilt_sha)"

if [[ "${ONLINE}" == "true" ]]; then
    ver="${_LAUREL_PINNED_VERSION#v}"
    url="${_LAUREL_RELEASE_URL}/${_LAUREL_PINNED_VERSION}/laurel-${ver}-x86_64-musl.tar.gz"
    tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
    echo "[INFO]  Fetching ${url} ..."
    if curl -fsSL --retry 3 --connect-timeout 15 -o "${tmp}/laurel.tar.gz" "${url}"; then
        check "pinned sha256 matches the asset upstream serves" \
            "${_LAUREL_PINNED_SHA256}" \
            "$(sha256sum "${tmp}/laurel.tar.gz" | awk '{print $1}')"
        tar xzf "${tmp}/laurel.tar.gz" -C "${tmp}"
        bin=( "${tmp}"/*/bin/laurel )
        check "the tarball's bin/laurel is where the installer globs for it" \
            "yes" "$([[ -x "${bin[0]}" ]] && echo yes || echo no)"
        # The whole point of the switch: no libc to be incompatible with.
        check "the release binary is statically linked" \
            "yes" "$(objdump -p "${bin[0]}" | grep -q NEEDED && echo no || echo yes)"
    else
        echo "[FAIL]  could not download ${url}"
        FAILED=$((FAILED + 1))
    fi
fi

echo
if (( FAILED > 0 )); then
    echo "${FAILED} check(s) failed."
    exit 1
fi
echo "All checks passed."

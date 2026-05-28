#!/usr/bin/env bash
# Integration test: build tarball, install from it, verify, then uninstall.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${HOME}/.local/share/cisco-console-capture"
TEST_BIN_DIR=$(mktemp -d)
export CONSOLE_CAPTURE_BIN_LINK="${TEST_BIN_DIR}/console-capture"
BIN_LINK="${CONSOLE_CAPTURE_BIN_LINK}"
MAN_DEST="${HOME}/.local/share/man/man1/console-capture.1.gz"
EXTRACT_DIR=""

PASS=0
FAIL=0

# -- Helpers -------------------------------------------------------------------

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass() { echo -e "${GREEN}  PASS${NC}  $*"; (( PASS++ )) || true; }
fail() { echo -e "${RED}  FAIL${NC}  $*"; (( FAIL++ )) || true; }

assert_exists()     { [[ -e "$1" ]] && pass "$1 exists"        || fail "$1 does not exist"; }
assert_not_exists() { [[ ! -e "$1" ]] && pass "$1 removed"     || fail "$1 still exists"; }
assert_executable() { [[ -x "$1" ]] && pass "$1 is executable" || fail "$1 is not executable"; }

# -- Cleanup -------------------------------------------------------------------

cleanup() {
    echo ""
    echo -e "${YELLOW}--- Cleanup ---${NC}"

    if [[ -x "${INSTALL_DIR}/uninstall.sh" ]]; then
        echo "Running uninstall.sh ..."
        "${INSTALL_DIR}/uninstall.sh"
    else
        echo "uninstall.sh not found; removing files manually ..."
        rm -f  "${BIN_LINK}"
        rm -f  "${MAN_DEST}"
        rm -rf "${INSTALL_DIR}"
    fi

    if [[ -n "${EXTRACT_DIR}" && -d "${EXTRACT_DIR}" ]]; then
        echo "Removing extracted tarball at ${EXTRACT_DIR} ..."
        rm -rf "${EXTRACT_DIR}"
    fi

    rm -rf "${TEST_BIN_DIR}"
}

trap cleanup EXIT

# -- Build ---------------------------------------------------------------------

echo -e "${YELLOW}--- Build ---${NC}"
if bash "${REPO_DIR}/build.sh"; then
    BUILD_OK=true
else
    BUILD_OK=false
    fail "build.sh exited with a non-zero status"
fi

if [[ "${BUILD_OK}" == true ]]; then
    TARBALL=$(ls -t "${REPO_DIR}/dist/"*.tar.gz 2>/dev/null | head -1)
    if [[ -n "${TARBALL}" ]]; then
        pass "tarball produced: $(basename "${TARBALL}")"
    else
        BUILD_OK=false
        fail "no tarball found in dist/"
    fi
fi

# -- Extract -------------------------------------------------------------------

if [[ "${BUILD_OK}" == true ]]; then
    echo ""
    echo -e "${YELLOW}--- Extract ---${NC}"
    EXTRACT_DIR=$(mktemp -d)
    tar -xzf "${TARBALL}" -C "${EXTRACT_DIR}"
    EXTRACTED_ROOT="${EXTRACT_DIR}/$(basename "${TARBALL}" .tar.gz)"

    if [[ -f "${EXTRACTED_ROOT}/install.sh" ]]; then
        pass "install.sh present in tarball"
    else
        BUILD_OK=false
        fail "install.sh missing from tarball"
    fi

    if [[ -d "${EXTRACTED_ROOT}/wheels" ]] && \
       [[ -n "$(ls "${EXTRACTED_ROOT}/wheels/"*.whl 2>/dev/null)" ]]; then
        WHEEL_COUNT=$(ls "${EXTRACTED_ROOT}/wheels/"*.whl | wc -l)
        pass "wheels/ contains ${WHEEL_COUNT} wheel(s)"
    else
        fail "wheels/ directory missing or empty in tarball"
    fi
fi

# -- Install -------------------------------------------------------------------

INSTALL_OK=false
if [[ "${BUILD_OK}" == true ]]; then
    echo ""
    echo -e "${YELLOW}--- Install ---${NC}"
    if bash "${EXTRACTED_ROOT}/install.sh"; then
        INSTALL_OK=true
    else
        fail "install.sh exited with a non-zero status"
    fi
fi

# -- Post-install assertions ---------------------------------------------------

if [[ "${INSTALL_OK}" == true ]]; then
    echo ""
    echo -e "${YELLOW}--- Post-install assertions ---${NC}"

    assert_exists     "${INSTALL_DIR}"
    assert_exists     "${INSTALL_DIR}/bin/console-capture"
    assert_executable "${INSTALL_DIR}/bin/console-capture"
    assert_exists     "${BIN_LINK}"
    assert_executable "${BIN_LINK}"
    assert_exists     "${INSTALL_DIR}/uninstall.sh"

    if [[ -f "${MAN_DEST}" ]]; then
        pass "${MAN_DEST} installed"
    else
        echo -e "${YELLOW}  SKIP${NC}  man page not installed (gzip/mandb may be unavailable)"
    fi

    VERSION_OUTPUT=$("${BIN_LINK}" --version 2>&1) || true
    if echo "${VERSION_OUTPUT}" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+"; then
        pass "--version returns a version string (${VERSION_OUTPUT})"
    else
        fail "--version did not return a version string (got: ${VERSION_OUTPUT})"
    fi
fi

# -- Summary -------------------------------------------------------------------

echo ""
echo -e "${YELLOW}--- Results ---${NC}"
echo -e "  Passed: ${GREEN}${PASS}${NC}"
echo -e "  Failed: ${RED}${FAIL}${NC}"
echo ""

[[ "${FAIL}" -eq 0 ]]

#!/usr/bin/env bash
# Device test: run console-capture against a live Cisco serial connection
# and assert that output files are created with the expected structure.
#
# Usage:
#   bash tests/test_device.sh -p /dev/ttyUSB0 [-u admin] [-P secret] [-b 9600]
#
# Flags match the main tool. Credentials are optional if the device has no login.
# Port may also be supplied via the CISCO_PORT env var (flag takes precedence).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=""

PASS=0
FAIL=0

# -- Helpers -------------------------------------------------------------------

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass()  { echo -e "${GREEN}  PASS${NC}  $*"; (( PASS++ )) || true; }
fail()  { echo -e "${RED}  FAIL${NC}  $*"; (( FAIL++ )) || true; }
skip()  { echo -e "${YELLOW}  SKIP${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

assert_file_exists()    { [[ -f "$1" ]] && pass "file exists: $(basename "$1")"          || fail "file not created: $1"; }
assert_file_nonempty()  { [[ -s "$1" ]] && pass "file is non-empty: $(basename "$1")"    || fail "file is empty: $1"; }
assert_contains()       { grep -q "$2" "$1" \
                            && pass "$(basename "$1") contains: $2" \
                            || fail "$(basename "$1") missing:  $2"; }
assert_not_contains()   { ! grep -q "$2" "$1" \
                            && pass "$(basename "$1") does not contain: $2" \
                            || fail "$(basename "$1") unexpectedly contains: $2"; }

# -- Cleanup -------------------------------------------------------------------

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        echo ""
        echo -e "${YELLOW}--- Cleanup ---${NC}"
        echo "Removing work directory ${WORK_DIR} ..."
        rm -rf "${WORK_DIR}"
    fi
}

trap cleanup EXIT

# -- Resolve binary ------------------------------------------------------------

if command -v console-capture &>/dev/null; then
    BIN="console-capture"
elif [[ -x "${REPO_DIR}/.venv/bin/console-capture" ]]; then
    BIN="${REPO_DIR}/.venv/bin/console-capture"
else
    die "console-capture not found. Install it or activate the dev venv first."
fi

# -- Parse arguments -----------------------------------------------------------

PORT="${CISCO_PORT:-}"
USERNAME="${CISCO_USER:-}"
PASSWORD="${CISCO_PASS:-}"
BAUD="${CISCO_BAUD:-9600}"

usage() {
    echo "Usage: $(basename "$0") -p PORT [-u USERNAME] [-P PASSWORD] [-b BAUD]"
    echo ""
    echo "  -p PORT        Serial device (e.g. /dev/ttyUSB0). Also: \$CISCO_PORT"
    echo "  -u USERNAME    Login username.                          Also: \$CISCO_USER"
    echo "  -P PASSWORD    Login password.                          Also: \$CISCO_PASS"
    echo "  -b BAUD        Baud rate (default: 9600).              Also: \$CISCO_BAUD"
    exit 1
}

while getopts ":p:u:P:b:h" opt; do
    case "${opt}" in
        p) PORT="${OPTARG}" ;;
        u) USERNAME="${OPTARG}" ;;
        P) PASSWORD="${OPTARG}" ;;
        b) BAUD="${OPTARG}" ;;
        h) usage ;;
        :) die "Option -${OPTARG} requires an argument."; usage ;;
        \?) die "Unknown option: -${OPTARG}"; usage ;;
    esac
done

[[ -z "${PORT}" ]] && die "Serial port is required. Use -p /dev/ttyUSB0 or set \$CISCO_PORT."
[[ -c "${PORT}" ]] || die "Device ${PORT} does not exist or is not a character device."

# Build credential flags for the CLI invocations
CRED_FLAGS=(-p "${PORT}" -b "${BAUD}")
[[ -n "${USERNAME}" ]] && CRED_FLAGS+=(-u "${USERNAME}")
[[ -n "${PASSWORD}" ]] && CRED_FLAGS+=(-P "${PASSWORD}")

# -- Setup ---------------------------------------------------------------------

WORK_DIR=$(mktemp -d)
echo -e "${YELLOW}--- Device tests (port: ${PORT}) ---${NC}"
echo "Work directory: ${WORK_DIR}"
echo "Binary:         ${BIN}"
echo ""

# -- Test 1: default commands, hostname-named output file ----------------------

echo -e "${YELLOW}--- Test 1: default commands + hostname filename ---${NC}"

"${BIN}" "${CRED_FLAGS[@]}" --output "${WORK_DIR}/t1.txt"

assert_file_exists   "${WORK_DIR}/t1.txt"
assert_file_nonempty "${WORK_DIR}/t1.txt"
assert_contains      "${WORK_DIR}/t1.txt" "COMMAND: show run brief"
assert_contains      "${WORK_DIR}/t1.txt" "COMMAND: show interfaces status"

# -- Test 2: hostname is used in the auto-generated filename -------------------

echo ""
echo -e "${YELLOW}--- Test 2: output filename uses device hostname ---${NC}"

# Run in the work dir so the auto-named file lands there
(cd "${WORK_DIR}" && "${BIN}" "${CRED_FLAGS[@]}")

HOSTNAME_FILE=$(ls "${WORK_DIR}"/*.txt 2>/dev/null | grep -v "^${WORK_DIR}/t[0-9]" | head -1 || true)
if [[ -n "${HOSTNAME_FILE}" ]]; then
    BASENAME=$(basename "${HOSTNAME_FILE}" .txt)
    # Filename should be <hostname>_<timestamp>, not the generic cisco_output_ prefix
    if [[ "${BASENAME}" == cisco_output_* ]]; then
        fail "filename uses fallback prefix 'cisco_output_' — hostname was not detected"
    else
        pass "output filename includes hostname: ${BASENAME}"
    fi
    assert_file_nonempty "${HOSTNAME_FILE}"
else
    fail "no auto-named output file found in ${WORK_DIR}"
fi

# -- Test 3: custom commands replace defaults ----------------------------------

echo ""
echo -e "${YELLOW}--- Test 3: custom commands via -c ---${NC}"

"${BIN}" "${CRED_FLAGS[@]}" \
    -c "show version" \
    -c "show ip interface brief" \
    --output "${WORK_DIR}/t3.txt"

assert_file_exists   "${WORK_DIR}/t3.txt"
assert_file_nonempty "${WORK_DIR}/t3.txt"
assert_contains      "${WORK_DIR}/t3.txt" "COMMAND: show version"
assert_contains      "${WORK_DIR}/t3.txt" "COMMAND: show ip interface brief"
assert_not_contains  "${WORK_DIR}/t3.txt" "COMMAND: show run brief"
assert_not_contains  "${WORK_DIR}/t3.txt" "COMMAND: show interfaces status"

# -- Test 4: single custom command ---------------------------------------------

echo ""
echo -e "${YELLOW}--- Test 4: single custom command ---${NC}"

"${BIN}" "${CRED_FLAGS[@]}" \
    -c "show version" \
    --output "${WORK_DIR}/t4.txt"

assert_file_exists   "${WORK_DIR}/t4.txt"
assert_file_nonempty "${WORK_DIR}/t4.txt"
assert_contains      "${WORK_DIR}/t4.txt" "COMMAND: show version"
assert_not_contains  "${WORK_DIR}/t4.txt" "COMMAND: show interfaces status"

# -- Summary -------------------------------------------------------------------

echo ""
echo -e "${YELLOW}--- Results ---${NC}"
echo -e "  Passed: ${GREEN}${PASS}${NC}"
echo -e "  Failed: ${RED}${FAIL}${NC}"
echo ""

[[ "${FAIL}" -eq 0 ]]

#!/usr/bin/env bash
# build.sh - Build a portable, self-contained installation tarball.
#
# Output: dist/cisco-console-capture-<version>.tar.gz
#
# The tarball contains pre-built wheels for the package and all runtime
# dependencies so the target machine needs no internet access to install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

command -v python3 &>/dev/null || error "python3 not found."

PYTHON=python3

# ---------------------------------------------------------------------------
# Version + paths
# ---------------------------------------------------------------------------

VERSION=$("$PYTHON" -c "from cisco_console_capture import __version__; print(__version__)")
ARCHIVE_NAME="cisco-console-capture-${VERSION}"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGE_DIR="${BUILD_DIR}/${ARCHIVE_NAME}"
WHEELS_DIR="${STAGE_DIR}/wheels"
DIST_DIR="${SCRIPT_DIR}/dist"
BUILD_VENV="${BUILD_DIR}/.build-venv"

info "Building ${ARCHIVE_NAME} ..."

# ---------------------------------------------------------------------------
# Isolated build venv (keeps the system Python untouched)
# ---------------------------------------------------------------------------

rm -rf "${STAGE_DIR}" "${BUILD_VENV}"
mkdir -p "${WHEELS_DIR}" "${DIST_DIR}"

info "Creating isolated build environment ..."
"$PYTHON" -m venv "${BUILD_VENV}"
"${BUILD_VENV}/bin/pip" install --quiet hatchling

# Build package wheel
info "Building package wheel ..."
"${BUILD_VENV}/bin/pip" wheel . --no-deps --quiet -w "${WHEELS_DIR}"

# Download runtime dependency wheels (pure-Python, platform-independent)
info "Downloading dependency wheels ..."
"${BUILD_VENV}/bin/pip" download pyserial pyudev \
    --only-binary :all: \
    --quiet \
    -d "${WHEELS_DIR}"

rm -rf "${BUILD_VENV}"

# Copy static files
cp uninstall.sh "${STAGE_DIR}/uninstall.sh"
chmod 755 "${STAGE_DIR}/uninstall.sh"

if [[ -d man ]]; then
    cp -r man "${STAGE_DIR}/man"
fi

# ---------------------------------------------------------------------------
# Generate the bundled install.sh (offline, no uv/internet required)
# ---------------------------------------------------------------------------

cat > "${STAGE_DIR}/install.sh" << 'INSTALL_EOF'
#!/usr/bin/env bash
# install.sh - Install Cisco Console Capture from bundled wheels (offline).
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/cisco-console-capture"
BIN_LINK="${CONSOLE_CAPTURE_BIN_LINK:-/usr/local/bin/console-capture}"
MAN_DIR="${HOME}/.local/share/man/man1"
MAN_DEST="${MAN_DIR}/console-capture.1.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHEELS_DIR="${SCRIPT_DIR}/wheels"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "$(uname -s)" != "Linux" ]] && error "This installer only runs on Linux."

sudo_run() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        error "sudo is not available. Cannot run: $*"
    fi
}

# -- Dependency helpers --------------------------------------------------------

_apt_install() {
    if [[ "$EUID" -eq 0 ]]; then
        apt-get install -y "$@"
    elif command -v sudo &>/dev/null; then
        sudo apt-get install -y "$@"
    else
        error "sudo is not available. Install $* manually and re-run."
    fi
}

# prompt_install <apt-package> <human description>
# Asks the user whether to install a missing dependency via apt.
# Aborts if the user declines or apt-get is unavailable.
prompt_install() {
    local pkg="$1"
    local desc="$2"
    warn "${desc} not found."
    if ! command -v apt-get &>/dev/null; then
        error "${desc} is required. Install it manually and re-run."
    fi
    read -r -p "  Install ${pkg} via apt now? [y/N] " response
    if [[ "${response}" =~ ^[Yy]$ ]]; then
        _apt_install "${pkg}"
    else
        error "${desc} is required. Aborting."
    fi
}

# -- Python 3.10+ --------------------------------------------------------------

find_python() {
    PYTHON=""
    for candidate in python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" &>/dev/null; then
            ver=$("$candidate" -c 'import sys; print(sys.version_info >= (3,10))')
            if [[ "$ver" == "True" ]]; then
                PYTHON="$candidate"
                return 0
            fi
        fi
    done
    return 1
}

if ! find_python; then
    prompt_install python3 "Python 3.10+"
    find_python || error "Python 3.10+ still not found after installation. Try: sudo apt install python3.12"
fi
info "Using $($PYTHON --version)"

# -- python3-venv --------------------------------------------------------------

if command -v dpkg-query &>/dev/null; then
    if ! dpkg-query -W -f='${Status}' python3-venv 2>/dev/null | grep -q "install ok installed"; then
        prompt_install python3-venv "python3-venv"
    fi
fi

# -- Create venv and install ---------------------------------------------------

info "Creating virtual environment at ${INSTALL_DIR} ..."
rm -rf "${INSTALL_DIR}"
"$PYTHON" -m venv "${INSTALL_DIR}"

info "Installing Cisco Console Capture from bundled wheels ..."
"${INSTALL_DIR}/bin/pip" install \
    --quiet \
    --no-cache-dir \
    --no-index \
    --find-links "${WHEELS_DIR}" \
    cisco-console-capture

# -- Wrapper script ------------------------------------------------------------

info "Installing command wrapper at ${BIN_LINK} ..."
TMP_WRAPPER=$(mktemp)
cat > "${TMP_WRAPPER}" << EOF
#!/usr/bin/env bash
exec "${INSTALL_DIR}/bin/console-capture" "\$@"
EOF
BIN_LINK_DIR=$(dirname "${BIN_LINK}")
if [[ -w "${BIN_LINK_DIR}" ]]; then
    install -m 755 "${TMP_WRAPPER}" "${BIN_LINK}"
else
    sudo_run install -m 755 "${TMP_WRAPPER}" "${BIN_LINK}"
fi
rm -f "${TMP_WRAPPER}"

# Record where the wrapper was placed so uninstall.sh removes the right file
echo "${BIN_LINK}" > "${INSTALL_DIR}/.bin_link"

cp "${SCRIPT_DIR}/uninstall.sh" "${INSTALL_DIR}/uninstall.sh"
chmod 755 "${INSTALL_DIR}/uninstall.sh"

# -- Man page ------------------------------------------------------------------

if [[ -f "${SCRIPT_DIR}/man/man1/console-capture.1" ]]; then
    if ! command -v gzip &>/dev/null; then
        prompt_install gzip "gzip"
    fi
    info "Installing man page ..."
    mkdir -p "${MAN_DIR}"
    gzip -c "${SCRIPT_DIR}/man/man1/console-capture.1" > "${MAN_DEST}"
    mandb -q "${HOME}/.local/share/man" 2>/dev/null || true
fi

# -- Done ----------------------------------------------------------------------

echo ""
info "Installation complete!"
echo ""
echo "  Command:  console-capture --help"
echo "  Man page: man console-capture"
echo ""

warn "Your user must be in the 'dialout' group to access serial ports."
echo "  Run:  sudo usermod -aG dialout \${USER}"
echo "  Then log out and back in."
echo ""
echo "  To uninstall:  ${INSTALL_DIR}/uninstall.sh"
echo ""
INSTALL_EOF
chmod 755 "${STAGE_DIR}/install.sh"

# ---------------------------------------------------------------------------
# Create tarball
# ---------------------------------------------------------------------------

TARBALL="${DIST_DIR}/${ARCHIVE_NAME}.tar.gz"
info "Creating ${TARBALL} ..."
tar -czf "${TARBALL}" -C "${BUILD_DIR}" "${ARCHIVE_NAME}"
rm -rf "${BUILD_DIR}"

echo ""
info "Done.  Artefact: ${TARBALL}"
echo ""
echo "  On the target machine:"
echo "    tar -xzf ${ARCHIVE_NAME}.tar.gz"
echo "    cd ${ARCHIVE_NAME}"
echo "    ./install.sh"
echo ""

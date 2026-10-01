#!/usr/bin/env bash
# uninstall.sh - Remove Cisco Console Capture
set -euo pipefail

# Install dir: explicit override, else the dir this script lives in when it is
# an installed copy (has .bin_link), else the default.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${CONSOLE_CAPTURE_INSTALL_DIR:-}" ]]; then
    INSTALL_DIR="${CONSOLE_CAPTURE_INSTALL_DIR}"
elif [[ -f "${SELF_DIR}/.bin_link" ]]; then
    INSTALL_DIR="${SELF_DIR}"
else
    INSTALL_DIR="${HOME}/.local/share/cisco-console-capture"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

sudo_run() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        error "sudo is not available. Cannot run: $*"
    fi
}

[[ "$(uname -s)" != "Linux" ]] && error "This script only runs on Linux."

# Resolve wrapper path from install record, fall back to default
if [[ -f "${INSTALL_DIR}/.bin_link" ]]; then
    BIN_LINK=$(cat "${INSTALL_DIR}/.bin_link")
else
    BIN_LINK="/usr/local/bin/console-capture"
fi

info "Removing ${BIN_LINK} ..."
BIN_LINK_DIR=$(dirname "${BIN_LINK}")
if [[ -w "${BIN_LINK_DIR}" ]]; then
    rm -f "${BIN_LINK}"
else
    sudo_run rm -f "${BIN_LINK}"
fi

# Resolve man page path from install record, fall back to default
if [[ -f "${INSTALL_DIR}/.man_dest" ]]; then
    MAN_DEST=$(cat "${INSTALL_DIR}/.man_dest")
else
    MAN_DEST="${HOME}/.local/share/man/man1/console-capture.1.gz"
fi

info "Removing ${MAN_DEST} ..."
rm -f "${MAN_DEST}"
mandb -q "$(dirname "$(dirname "${MAN_DEST}")")" 2>/dev/null || true

info "Removing ${INSTALL_DIR} ..."
rm -rf "${INSTALL_DIR}"

info "Cisco Console Capture has been uninstalled."

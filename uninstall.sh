#!/usr/bin/env bash
# uninstall.sh - Remove Cisco Console Capture
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/cisco-console-capture"
MAN_DEST="${HOME}/.local/share/man/man1/console-capture.1.gz"

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

info "Removing ${MAN_DEST} ..."
rm -f "${MAN_DEST}"
mandb -q "${HOME}/.local/share/man" 2>/dev/null || true

info "Removing ${INSTALL_DIR} ..."
rm -rf "${INSTALL_DIR}"

info "Cisco Console Capture has been uninstalled."

#!/usr/bin/env bash
set -euo pipefail

# install.sh - set up the custom WSL kernel updater and its login update-check.
#
# Installs:
#   - update-custom-wsl-kernel.sh -> $INSTALL_DIR        (default /usr/local/bin)
#   - wsl-kernel-check.sh         -> $PROFILE_D/wsl-kernel-check.sh (default /etc/profile.d)
#
# Run from a checkout of this repo, or standalone:
#   curl -fsSL https://raw.githubusercontent.com/faratech/wsl-linux-port-builder/main/client/install.sh | bash
#
# Options:
#   --prefix DIR   install the updater into DIR (default /usr/local/bin)
#   --no-check     do not install the login update-check hook
#   --uninstall    remove the installed updater and hook
#   -h, --help     show this help
#
# Env overrides: INSTALL_DIR, PROFILE_D, RAW_BASE.

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
PROFILE_D="${PROFILE_D:-/etc/profile.d}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/faratech/wsl-linux-port-builder/main/client}"
WANT_CHECK=1
UNINSTALL=0

info()  { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() { sed -n '4,19p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) INSTALL_DIR="${2:?--prefix needs a directory}"; shift 2 ;;
        --no-check) WANT_CHECK=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1 (try --help)" ;;
    esac
done

SUDO=""
if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        error "Need root to write to $INSTALL_DIR and $PROFILE_D. Re-run as root or install sudo."
    fi
fi

UPDATER_DEST="$INSTALL_DIR/update-custom-wsl-kernel.sh"
HOOK_DEST="$PROFILE_D/wsl-kernel-check.sh"

if [[ "$UNINSTALL" -eq 1 ]]; then
    $SUDO rm -f "$UPDATER_DEST" "$HOOK_DEST"
    info "Removed $UPDATER_DEST and $HOOK_DEST"
    exit 0
fi

# Use the sibling files when run from a repo checkout; otherwise download them.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
[[ -n "$SRC_DIR" && -f "$SRC_DIR/install.sh" ]] || SRC_DIR=""

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

obtain() {
    local name="$1"
    if [[ -n "$SRC_DIR" && -f "$SRC_DIR/$name" ]]; then
        cp "$SRC_DIR/$name" "$tmp/$name"
    else
        command -v curl >/dev/null 2>&1 || error "curl is required to fetch $name"
        info "Downloading $name from $RAW_BASE..."
        curl -fsSL "$RAW_BASE/$name" -o "$tmp/$name"
    fi
}

obtain update-custom-wsl-kernel.sh
$SUDO install -D -m 0755 "$tmp/update-custom-wsl-kernel.sh" "$UPDATER_DEST"
info "Installed updater: $UPDATER_DEST"

if [[ "$WANT_CHECK" -eq 1 ]]; then
    obtain wsl-kernel-check.sh
    # Point the hook's default candidate at the chosen install location.
    if [[ "$UPDATER_DEST" != "/usr/local/bin/update-custom-wsl-kernel.sh" ]]; then
        sed -i "s#/usr/local/bin/update-custom-wsl-kernel.sh#$UPDATER_DEST#g" "$tmp/wsl-kernel-check.sh"
    fi
    $SUDO install -D -m 0755 "$tmp/wsl-kernel-check.sh" "$HOOK_DEST"
    info "Installed login check: $HOOK_DEST"
fi

info "Done. Open a new shell (or 'source $HOOK_DEST') to see update notices."
info "Run an update any time with: $UPDATER_DEST"

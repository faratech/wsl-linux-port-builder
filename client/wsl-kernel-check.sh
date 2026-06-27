#!/bin/bash
# Custom WSL kernel update check shown at login (non-blocking).
#
# Installed to /etc/profile.d/ by client/install.sh. Safe to copy by hand too.
# It prefers the full updater's own "--check"; if that is not installed it falls
# back to a generic notice comparing the running kernel to the latest stock
# Microsoft WSL release.
(
    # Preferred path: the custom-port updater. Override with CUSTOM_WSL_UPDATER.
    # install.sh rewrites the default below to wherever it installed the updater.
    for candidate in \
        "${CUSTOM_WSL_UPDATER:-/usr/local/bin/update-custom-wsl-kernel.sh}" \
        /mnt/c/code/update-custom-wsl-kernel.sh; do
        if [ -x "$candidate" ]; then
            "$candidate" --check 2>/dev/null || true
            exit 0
        fi
    done

    # Fallback runs only when the updater is not installed. Skip on a custom port
    # kernel (uname ends with WSL2+), where comparing to stock WSL is misleading.
    case "$(uname -r)" in
        *WSL2+) exit 0 ;;
    esac

    kernel_base_version() {
        printf '%s\n' "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//; s/[.]+$//'
    }
    version_gt() {
        [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
    }

    CURRENT="$(kernel_base_version "$(uname -r)")"
    [ -z "$CURRENT" ] && exit 0
    LATEST="$(curl -sf --max-time 3 \
        "https://api.github.com/repos/microsoft/WSL2-Linux-Kernel/releases?per_page=1" \
        | grep -oP '"tag_name":\s*"linux-msft-wsl-\K[0-9.]+' | head -1)"
    [ -z "$LATEST" ] && exit 0
    version_gt "$LATEST" "$CURRENT" || exit 0

    printf '\033[1;33m[WSL Kernel] Microsoft WSL kernel update available: %s -> %s\033[0m\n' \
        "$CURRENT" "$LATEST"
    printf '\033[0;33m  Install the custom-port updater: %s\033[0m\n' \
        "https://github.com/faratech/wsl-linux-port-builder#install"
) & disown

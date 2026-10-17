#!/bin/bash
# install.sh - Install nuvemlabs/secrets
#
# Per-user (default):  ~/.local/lib/secrets + ~/.local/bin
# Packaged:            PREFIX=/usr DESTDIR="$pkgdir" ./install.sh
#                      -> $DESTDIR$PREFIX/lib/secrets + $DESTDIR$PREFIX/bin
# SECRETS_INSTALL_DIR / SECRETS_BIN_DIR override either layout.
#
# Personal, opt-in:    ./install.sh --aur-watch
#                      -> aur-registration-watch in ~/.local/bin + its systemd
#                      user timer (SECRETS_SYSTEMD_USER_DIR overrides the unit
#                      dir; SECRETS_SKIP_SYSTEMCTL=1 skips enabling the timer).
#                      Installs only the watcher; never part of a package.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_aur_watch() {
    if [[ -n "${PREFIX:-}" || -n "${DESTDIR:-}" ]]; then
        echo "[secrets] --aur-watch is a per-user install; unset PREFIX and DESTDIR" >&2
        exit 1
    fi
    local bin_dir="${SECRETS_BIN_DIR:-$HOME/.local/bin}"
    local unit_dir="${SECRETS_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
    local unit="aur-registration-watch"

    echo "[secrets] Installing $unit to $bin_dir"
    install -d "$bin_dir" "$unit_dir"
    install -m 755 "$SOURCE_DIR/scripts/$unit" "$bin_dir/"

    echo "[secrets] Installing $unit.service and $unit.timer to $unit_dir"
    sed "s|@BIN_DIR@|$bin_dir|g" "$SOURCE_DIR/scripts/systemd/$unit.service" > "$unit_dir/$unit.service"
    install -m 644 "$SOURCE_DIR/scripts/systemd/$unit.timer" "$unit_dir/"

    if [[ "${SECRETS_SKIP_SYSTEMCTL:-0}" == "1" ]]; then
        echo "[secrets] Skipped enabling the timer (SECRETS_SKIP_SYSTEMCTL=1)"
    else
        systemctl --user daemon-reload
        systemctl --user enable --now "$unit.timer"
        echo "[secrets] $unit.timer enabled: systemctl --user list-timers $unit.timer"
    fi
}

if [[ "${1:-}" == "--aur-watch" ]]; then
    install_aur_watch
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--aur-watch]" >&2
    exit 2
fi

if [[ -n "${PREFIX:-}" ]]; then
    DEFAULT_LIB_DIR="$PREFIX/lib/secrets"
    DEFAULT_BIN_DIR="$PREFIX/bin"
else
    DEFAULT_LIB_DIR="$HOME/.local/lib/secrets"
    DEFAULT_BIN_DIR="$HOME/.local/bin"
fi

# Final (runtime) locations; DESTDIR only stages them for a package build
INSTALL_DIR="${SECRETS_INSTALL_DIR:-$DEFAULT_LIB_DIR}"
BIN_DIR="${SECRETS_BIN_DIR:-$DEFAULT_BIN_DIR}"
DESTDIR="${DESTDIR:-}"

echo "[secrets] Installing library to $DESTDIR$INSTALL_DIR"
install -d "$DESTDIR$INSTALL_DIR/backends"
install -m 644 "$SOURCE_DIR/secrets.sh" "$DESTDIR$INSTALL_DIR/"
install -m 644 "$SOURCE_DIR/backends/"*.sh "$DESTDIR$INSTALL_DIR/backends/"

echo "[secrets] Installing CLI tools to $DESTDIR$BIN_DIR"
install -d "$DESTDIR$BIN_DIR"
install -m 755 "$SOURCE_DIR/bin/"* "$DESTDIR$BIN_DIR/"

echo "[secrets] Installed successfully"
echo ""
echo "Add to your shell rc file:"
echo "  source \"$INSTALL_DIR/secrets.sh\""
echo ""
echo "Ensure $BIN_DIR is on your PATH for the CLI tools (secrets-doctor)."

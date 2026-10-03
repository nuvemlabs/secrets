#!/bin/bash
# install.sh - Install nuvemlabs/secrets
#
# Per-user (default):  ~/.local/lib/secrets + ~/.local/bin
# Packaged:            PREFIX=/usr DESTDIR="$pkgdir" ./install.sh
#                      -> $DESTDIR$PREFIX/lib/secrets + $DESTDIR$PREFIX/bin
# SECRETS_INSTALL_DIR / SECRETS_BIN_DIR override either layout.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

#!/bin/bash
# install.sh - Install nuvemlabs/secrets to ~/.local/lib/secrets/
set -euo pipefail

INSTALL_DIR="${SECRETS_INSTALL_DIR:-$HOME/.local/lib/secrets}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[secrets] Installing to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/backends"

cp "$SOURCE_DIR/secrets.sh" "$INSTALL_DIR/"
cp "$SOURCE_DIR/backends/"*.sh "$INSTALL_DIR/backends/"

chmod +x "$INSTALL_DIR/secrets.sh"

echo "[secrets] Installed successfully"
echo ""
echo "Add to your shell rc file:"
echo "  source \"$INSTALL_DIR/secrets.sh\""

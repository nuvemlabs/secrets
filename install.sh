#!/bin/bash
# install.sh - Install nuvemlabs/secrets to ~/.local/lib/secrets/
set -euo pipefail

INSTALL_DIR="${SECRETS_INSTALL_DIR:-$HOME/.local/lib/secrets}"
BIN_DIR="${SECRETS_BIN_DIR:-$HOME/.local/bin}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[secrets] Installing to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/backends"

cp "$SOURCE_DIR/secrets.sh" "$INSTALL_DIR/"
cp "$SOURCE_DIR/backends/"*.sh "$INSTALL_DIR/backends/"

chmod +x "$INSTALL_DIR/secrets.sh"

echo "[secrets] Installing CLI tools to $BIN_DIR"

mkdir -p "$BIN_DIR"

cp "$SOURCE_DIR/bin/"* "$BIN_DIR/"
chmod +x "$BIN_DIR/secrets-doctor"

echo "[secrets] Installed successfully"
echo ""
echo "Add to your shell rc file:"
echo "  source \"$INSTALL_DIR/secrets.sh\""
echo ""
echo "Ensure $BIN_DIR is on your PATH for the CLI tools (secrets-doctor)."

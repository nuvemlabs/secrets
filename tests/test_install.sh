#!/bin/bash
# test_install.sh - Tests for install.sh layouts
#
# Hermetic: every run installs into a temp dir, HOME included, so the
# user's real ~/.local is never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/../install.sh"

PASS_COUNT=0
FAIL_COUNT=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
#   Test Helpers
# ─────────────────────────────────────────────────────────────────────────────

assert_file() {
    local test_name="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (missing $path)"
        ((FAIL_COUNT++)) || true
    fi
}

assert_absent() {
    local test_name="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (unexpected $path)"
        ((FAIL_COUNT++)) || true
    fi
}

assert_contains() {
    local test_name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (output did not contain '$needle')"
        ((FAIL_COUNT++)) || true
    fi
}

assert_not_contains() {
    local test_name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (output contained '$needle')"
        ((FAIL_COUNT++)) || true
    fi
}

assert_layout() {
    local label="$1" lib="$2" bin="$3"
    assert_file "$label: library" "$lib/secrets.sh"
    assert_file "$label: libsecret backend" "$lib/backends/libsecret.sh"
    assert_file "$label: file backend" "$lib/backends/file.sh"
    if [[ -x "$bin/secrets-doctor" ]]; then
        echo "  PASS: $label: secrets-doctor executable"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $label: secrets-doctor missing or not executable"
        ((FAIL_COUNT++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== install.sh Tests ==="

echo "-- default: per-user ~/.local --"
home="$TMPDIR_TEST/home"
HOME="$home" bash "$INSTALLER" >/dev/null
assert_layout "default" "$home/.local/lib/secrets" "$home/.local/bin"

echo "-- legacy overrides still win --"
HOME="$home" SECRETS_INSTALL_DIR="$TMPDIR_TEST/lib-o" SECRETS_BIN_DIR="$TMPDIR_TEST/bin-o" \
    bash "$INSTALLER" >/dev/null
assert_layout "overrides" "$TMPDIR_TEST/lib-o" "$TMPDIR_TEST/bin-o"

echo "-- PREFIX + DESTDIR: packaged layout --"
stage="$TMPDIR_TEST/stage"
pkg_home="$TMPDIR_TEST/pkg-home"
out="$(HOME="$pkg_home" PREFIX=/usr DESTDIR="$stage" bash "$INSTALLER")"
assert_layout "packaged" "$stage/usr/lib/secrets" "$stage/usr/bin"
assert_contains "packaged: rc hint names the final path" "$out" 'source "/usr/lib/secrets/secrets.sh"'
rc_hint="$(grep -A1 'Add to your shell rc' <<<"$out" | tail -1)"
assert_not_contains "packaged: rc hint omits the staging dir" "$rc_hint" "$stage"
assert_absent "packaged: nothing written to ~/.local" "$pkg_home/.local"

echo "-- installed doctor finds its library --"
doctor_out="$(HOME="$TMPDIR_TEST/empty-home" SECRETS_EXPORTS_FILE=/dev/null \
    "$stage/usr/bin/secrets-doctor" SOMEKEY 2>&1 || true)"
assert_not_contains "packaged doctor: library found" "$doctor_out" "library not found"

# ─────────────────────────────────────────────────────────────────────────────
#   Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ $FAIL_COUNT -eq 0 ]]

#!/bin/bash
# test_credmanager.sh - Tests for Windows Credential Manager backend
#
# Uses a unique test namespace to avoid polluting real credentials.
# Automatically cleans up test entries on exit.
# Skips if PowerShell is not available (non-Windows environments).

set -euo pipefail

# Detect PowerShell binary
SECRETS_POWERSHELL=""
if command -v powershell.exe &>/dev/null; then
    SECRETS_POWERSHELL="powershell.exe"
elif command -v pwsh &>/dev/null; then
    SECRETS_POWERSHELL="pwsh"
else
    echo "SKIP: Neither 'powershell.exe' nor 'pwsh' available"
    exit 0
fi
export SECRETS_POWERSHELL

# Verify CredentialManager module is available (check for actual output, not just exit code)
module_check=$("$SECRETS_POWERSHELL" -NoProfile -NonInteractive -Command "Get-Module -ListAvailable CredentialManager" 2>/dev/null | tr -d '\r\n ')
if [[ -z "$module_check" ]]; then
    echo "SKIP: CredentialManager PowerShell module not installed"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
#   Test Setup
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../backends/credmanager.sh
source "$SCRIPT_DIR/../backends/credmanager.sh"

# Use a unique test namespace to isolate test data
SECRETS_SERVICE="secrets-test-$$"

PASS_COUNT=0
FAIL_COUNT=0
TEST_KEYS=()

cleanup() {
    # Delete all test entries created during this run
    local ps
    ps=$(__credmanager_powershell)
    for key in "${TEST_KEYS[@]}"; do
        "$ps" -NoProfile -NonInteractive -Command \
            "Remove-StoredCredential -Target '${SECRETS_SERVICE}:${key}'" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
#   Test Helpers
# ─────────────────────────────────────────────────────────────────────────────

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $test_name"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $test_name (expected='$expected', actual='$actual')"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_empty() {
    local test_name="$1"
    local actual="$2"
    if [[ -z "$actual" ]]; then
        echo "  PASS: $test_name"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $test_name (expected empty, got='$actual')"
        (( FAIL_COUNT++ )) || true
    fi
}

register_key() {
    TEST_KEYS+=("$1")
}

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Windows Credential Manager Backend Tests ==="
echo "  Service namespace: $SECRETS_SERVICE"
echo "  PowerShell binary: $SECRETS_POWERSHELL"
echo ""

# Test: set and get a secret
echo "-- set/get --"
register_key "test-key-1"
__secret_set_credmanager "test-key-1" "hello-world"
result=$(__secret_get_credmanager "test-key-1")
assert_eq "set then get returns correct value" "hello-world" "$result"

# Test: update existing secret
echo "-- update existing --"
__secret_set_credmanager "test-key-1" "updated-value"
result=$(__secret_get_credmanager "test-key-1")
assert_eq "update overwrites previous value" "updated-value" "$result"

# Test: get nonexistent key returns empty
echo "-- get nonexistent --"
result=$(__secret_get_credmanager "nonexistent-key-$$" || true)
assert_empty "nonexistent key returns empty" "$result"

# Test: special characters in values
echo "-- special characters --"
register_key "test-special"
__secret_set_credmanager "test-special" 'p@$$w0rd!#%^&*()'
result=$(__secret_get_credmanager "test-special")
assert_eq "special characters preserved" 'p@$$w0rd!#%^&*()' "$result"

# Test: list secrets
echo "-- list --"
register_key "test-list-a"
register_key "test-list-b"
__secret_set_credmanager "test-list-a" "val-a"
__secret_set_credmanager "test-list-b" "val-b"
list_output=$(__secret_list_credmanager)
if echo "$list_output" | grep -q "test-list-a" && echo "$list_output" | grep -q "test-list-b"; then
    echo "  PASS: list contains test keys"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: list missing test keys (output: $list_output)"
    (( FAIL_COUNT++ )) || true
fi

# Test: delete secret
echo "-- delete --"
register_key "test-delete"
__secret_set_credmanager "test-delete" "to-be-deleted"
__secret_delete_credmanager "test-delete"
result=$(__secret_get_credmanager "test-delete" || true)
assert_empty "deleted key returns empty" "$result"

# ─────────────────────────────────────────────────────────────────────────────
#   Results
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

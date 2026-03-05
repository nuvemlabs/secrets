#!/bin/bash
# test_keychain.sh - Tests for macOS Keychain backend
#
# Uses a unique test namespace to avoid polluting real secrets.
# Automatically cleans up test entries on exit.

set -euo pipefail

# Skip if not on macOS
if [[ "$OSTYPE" != darwin* ]]; then
    echo "SKIP: Not on macOS (OSTYPE=$OSTYPE)"
    exit 0
fi

# Skip if security command not available
if ! command -v security &>/dev/null; then
    echo "SKIP: 'security' command not found"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
#   Test Setup
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../backends/keychain.sh
source "$SCRIPT_DIR/../backends/keychain.sh"

# Use a unique test namespace to isolate test data
SECRETS_SERVICE="secrets-test-$$"

PASS_COUNT=0
FAIL_COUNT=0
TEST_KEYS=()

cleanup() {
    # Delete all test entries created during this run
    for key in "${TEST_KEYS[@]}"; do
        security delete-generic-password -a "$key" -s "$SECRETS_SERVICE" &>/dev/null || true
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

assert_not_empty() {
    local test_name="$1"
    local actual="$2"
    if [[ -n "$actual" ]]; then
        echo "  PASS: $test_name"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $test_name (expected non-empty, got empty)"
        (( FAIL_COUNT++ )) || true
    fi
}

register_key() {
    TEST_KEYS+=("$1")
}

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== macOS Keychain Backend Tests ==="
echo "  Service namespace: $SECRETS_SERVICE"
echo ""

# Test: set and get a secret
echo "-- set/get --"
register_key "test-key-1"
__secret_set_keychain "test-key-1" "hello-world"
result=$(__secret_get_keychain "test-key-1")
assert_eq "set then get returns correct value" "hello-world" "$result"

# Test: update existing secret
echo "-- update existing --"
__secret_set_keychain "test-key-1" "updated-value"
result=$(__secret_get_keychain "test-key-1")
assert_eq "update overwrites previous value" "updated-value" "$result"

# Test: get nonexistent key returns empty
echo "-- get nonexistent --"
result=$(__secret_get_keychain "nonexistent-key-$$" || true)
assert_empty "nonexistent key returns empty" "$result"

# Test: special characters in values
echo "-- special characters --"
register_key "test-special"
__secret_set_keychain "test-special" 'p@$$w0rd!#%^&*(){}[]|'
result=$(__secret_get_keychain "test-special")
assert_eq "special characters preserved" 'p@$$w0rd!#%^&*(){}[]|' "$result"

# Test: spaces in values
echo "-- spaces in values --"
register_key "test-spaces"
__secret_set_keychain "test-spaces" "hello world with spaces"
result=$(__secret_get_keychain "test-spaces")
assert_eq "spaces in value preserved" "hello world with spaces" "$result"

# Test: list secrets
echo "-- list --"
register_key "test-list-a"
register_key "test-list-b"
__secret_set_keychain "test-list-a" "val-a"
__secret_set_keychain "test-list-b" "val-b"
list_output=$(__secret_list_keychain)
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
__secret_set_keychain "test-delete" "to-be-deleted"
__secret_delete_keychain "test-delete"
result=$(__secret_get_keychain "test-delete" || true)
assert_empty "deleted key returns empty" "$result"

# ─────────────────────────────────────────────────────────────────────────────
#   Results
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

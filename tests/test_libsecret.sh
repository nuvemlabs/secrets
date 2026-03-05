#!/bin/bash
# test_libsecret.sh - Tests for Linux libsecret backend
#
# Uses a unique test namespace to avoid polluting real secrets.
# Automatically cleans up test entries on exit.

set -euo pipefail

# Skip if secret-tool is not available
if ! command -v secret-tool &>/dev/null; then
    echo "SKIP: 'secret-tool' not found (libsecret-tools not installed)"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
#   Test Setup
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../backends/libsecret.sh
source "$SCRIPT_DIR/../backends/libsecret.sh"

# Use a unique test namespace to isolate test data
SECRETS_SERVICE="secrets-test-$$"

PASS_COUNT=0
FAIL_COUNT=0
TEST_KEYS=()

cleanup() {
    # Delete all test entries created during this run
    for key in "${TEST_KEYS[@]}"; do
        secret-tool clear service "$SECRETS_SERVICE" key "$key" 2>/dev/null || true
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

echo "=== Linux libsecret Backend Tests ==="
echo "  Service namespace: $SECRETS_SERVICE"
echo ""

# Test: set and get a secret
echo "-- set/get --"
register_key "test-key-1"
__secret_set_libsecret "test-key-1" "hello-world"
result=$(__secret_get_libsecret "test-key-1")
assert_eq "set then get returns correct value" "hello-world" "$result"

# Test: update existing secret
echo "-- update existing --"
__secret_set_libsecret "test-key-1" "updated-value"
result=$(__secret_get_libsecret "test-key-1")
assert_eq "update overwrites previous value" "updated-value" "$result"

# Test: get nonexistent key returns empty
echo "-- get nonexistent --"
result=$(__secret_get_libsecret "nonexistent-key-$$" || true)
assert_empty "nonexistent key returns empty" "$result"

# Test: special characters in values
echo "-- special characters --"
register_key "test-special"
__secret_set_libsecret "test-special" 'p@$$w0rd!#%^&*(){}[]|'
result=$(__secret_get_libsecret "test-special")
assert_eq "special characters preserved" 'p@$$w0rd!#%^&*(){}[]|' "$result"

# Test: list secrets
echo "-- list --"
register_key "test-list-a"
register_key "test-list-b"
__secret_set_libsecret "test-list-a" "val-a"
__secret_set_libsecret "test-list-b" "val-b"
list_output=$(__secret_list_libsecret)
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
__secret_set_libsecret "test-delete" "to-be-deleted"
__secret_delete_libsecret "test-delete"
result=$(__secret_get_libsecret "test-delete" || true)
assert_empty "deleted key returns empty" "$result"

# ─────────────────────────────────────────────────────────────────────────────
#   Results
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

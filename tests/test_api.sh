#!/bin/bash
# test_api.sh - Tests for the secrets.sh public API
#
# Sources the main secrets.sh entry point and exercises all public functions.
# Uses a unique test namespace to avoid polluting real secrets.
# Automatically cleans up test entries on exit.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#   Test Setup
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set test namespace BEFORE sourcing secrets.sh so it picks up our service
SECRETS_SERVICE="secrets-test-$$"
export SECRETS_SERVICE

# shellcheck source=../secrets.sh
source "$SCRIPT_DIR/../secrets.sh"

PASS_COUNT=0
FAIL_COUNT=0
TEST_KEYS=()

cleanup() {
    # Delete all test entries created during this run
    for key in "${TEST_KEYS[@]}"; do
        secret_delete "$key" &>/dev/null || true
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

assert_exit_code() {
    local test_name="$1"
    local expected_code="$2"
    shift 2
    local actual_code=0
    "$@" &>/dev/null || actual_code=$?
    if [[ "$actual_code" -eq "$expected_code" ]]; then
        echo "  PASS: $test_name"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $test_name (expected exit $expected_code, got $actual_code)"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $test_name"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $test_name (expected to contain '$needle')"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_stderr_not_empty() {
    local test_name="$1"
    shift
    local stderr_output
    stderr_output=$("$@" 2>&1 1>/dev/null || true)
    if [[ -n "$stderr_output" ]]; then
        echo "  PASS: $test_name"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $test_name (expected stderr output, got none)"
        (( FAIL_COUNT++ )) || true
    fi
}

register_key() {
    TEST_KEYS+=("$1")
}

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Public API Tests ==="
echo "  Service namespace: $SECRETS_SERVICE"
echo "  Detected backend:  $__SECRETS_BACKEND"
echo ""

# Skip set/get/delete/list tests if backend is file-only (read-only)
if [[ "$__SECRETS_BACKEND" == "file" ]]; then
    echo "SKIP: File backend is read-only; skipping set/get/delete/list mutation tests"
    echo ""
else

    # Test: secret_set then secret returns value
    echo "-- secret_set + secret (get) --"
    register_key "api-test-key-1"
    secret_set "api-test-key-1" "test-value-42"
    result=$(secret "api-test-key-1")
    assert_eq "secret_set then secret returns correct value" "test-value-42" "$result"

    # Test: secret for nonexistent key returns exit 1 and stderr message
    echo "-- secret nonexistent key --"
    assert_exit_code "nonexistent key returns exit 1" 1 secret "nonexistent-key-$$"
    assert_stderr_not_empty "nonexistent key writes to stderr" secret "nonexistent-key-$$"

    # Test: secret_set with empty args returns exit 1
    echo "-- secret_set empty args --"
    assert_exit_code "secret_set with no args returns exit 1" 1 secret_set
    assert_exit_code "secret_set with key only returns exit 1" 1 secret_set "some-key"
    assert_exit_code "secret_set with empty key returns exit 1" 1 secret_set "" "some-value"

    # Test: secret_delete removes the key
    echo "-- secret_delete --"
    register_key "api-test-delete"
    secret_set "api-test-delete" "delete-me"
    # Verify it exists first
    result=$(secret "api-test-delete")
    assert_eq "key exists before delete" "delete-me" "$result"
    # Delete it
    secret_delete "api-test-delete"
    # Verify it's gone
    assert_exit_code "deleted key returns exit 1" 1 secret "api-test-delete"

    # Test: secret_list includes stored keys
    echo "-- secret_list --"
    register_key "api-test-list-a"
    register_key "api-test-list-b"
    secret_set "api-test-list-a" "val-a"
    secret_set "api-test-list-b" "val-b"
    list_output=$(secret_list)
    assert_contains "list contains api-test-list-a" "api-test-list-a" "$list_output"
    assert_contains "list contains api-test-list-b" "api-test-list-b" "$list_output"

fi

# Test: secret --help prints usage (works on all backends)
echo "-- secret --help --"
help_output=$(secret --help 2>&1)
assert_contains "secret --help contains Usage" "Usage:" "$help_output"
assert_contains "secret --help mentions --all" "--all" "$help_output"

# Test: secret_set --help prints usage
echo "-- secret_set --help --"
help_output=$(secret_set --help 2>&1)
assert_contains "secret_set --help contains Usage" "Usage:" "$help_output"

# Test: secret_delete --help prints usage
echo "-- secret_delete --help --"
help_output=$(secret_delete --help 2>&1)
assert_contains "secret_delete --help contains Usage" "Usage:" "$help_output"

# Test: secret_list --help prints usage
echo "-- secret_list --help --"
help_output=$(secret_list --help 2>&1)
assert_contains "secret_list --help contains Usage" "Usage:" "$help_output"

# Test: backend detection returns a valid backend name
echo "-- backend detection --"
detected=$(__secrets_backend)
case "$detected" in
    keychain|credmanager|libsecret|file)
        echo "  PASS: backend detection returned valid name ($detected)"
        (( PASS_COUNT++ )) || true
        ;;
    *)
        echo "  FAIL: backend detection returned unknown name ($detected)"
        (( FAIL_COUNT++ )) || true
        ;;
esac

# Test: cached backend matches detection function
echo "-- cached backend consistency --"
assert_eq "cached backend matches detection" "$detected" "$__SECRETS_BACKEND"

# Test: SECRETS_DIR is set and valid
echo "-- SECRETS_DIR --"
if [[ -d "$SECRETS_DIR" && -f "$SECRETS_DIR/secrets.sh" ]]; then
    echo "  PASS: SECRETS_DIR points to valid directory with secrets.sh"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: SECRETS_DIR='$SECRETS_DIR' is not valid"
    (( FAIL_COUNT++ )) || true
fi

# Test: SECRETS_SERVICE was preserved from our pre-source setting
echo "-- SECRETS_SERVICE preserved --"
assert_eq "SECRETS_SERVICE preserved from caller" "secrets-test-$$" "$SECRETS_SERVICE"

# Test: aliases exist
echo "-- aliases --"
if type sl &>/dev/null; then
    echo "  PASS: sl alias exists"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: sl alias not defined"
    (( FAIL_COUNT++ )) || true
fi

if type sfz &>/dev/null; then
    echo "  PASS: sfz alias exists"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: sfz alias not defined"
    (( FAIL_COUNT++ )) || true
fi

# Test: secret_delete with empty key returns exit 1
echo "-- secret_delete empty args --"
assert_exit_code "secret_delete with no args returns exit 1" 1 secret_delete

# ─────────────────────────────────────────────────────────────────────────────
#   Results
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

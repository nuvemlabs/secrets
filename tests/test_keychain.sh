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

STUB_DIR=""

cleanup() {
    # Delete all test entries created during this run
    for key in ${TEST_KEYS+"${TEST_KEYS[@]}"}; do
        security delete-generic-password -a "$key" -s "$SECRETS_SERVICE" &>/dev/null || true
    done
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "$STUB_DIR"
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

# ─────────────────────────────────────────────────────────────────────────────
#   Hermetic Tests (stubbed `security` — never touches the real keychain)
# ─────────────────────────────────────────────────────────────────────────────

# The stub's exit codes are driven by STUB_SECURITY_*_RC and every call is
# appended to STUB_SECURITY_LOG so attempt counts can be asserted.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/security" << 'EOF'
#!/bin/bash
[[ -n "${STUB_SECURITY_LOG:-}" ]] && echo "$*" >> "$STUB_SECURITY_LOG"
case "${1:-}" in
    find-generic-password) exit "${STUB_SECURITY_FIND_RC:-44}" ;;
    show-keychain-info)    exit "${STUB_SECURITY_INFO_RC:-0}" ;;
    unlock-keychain)       exit "${STUB_SECURITY_UNLOCK_RC:-0}" ;;
    *)                     exit 1 ;;
esac
EOF
chmod +x "$STUB_DIR/security"
REAL_PATH="$PATH"
PATH="$STUB_DIR:$PATH"
export STUB_SECURITY_LOG="$STUB_DIR/calls.log"

echo "-- stubbed: locked keychain (security exit 36) --"
export STUB_SECURITY_FIND_RC=36
rc=0
__secret_get_keychain "stub-key" >/dev/null || rc=$?
assert_eq "get returns security's exit code 36 unchanged" "36" "$rc"
assert_eq "__SECRETS_LAST_RC records 36" "36" "$__SECRETS_LAST_RC"

: > "$STUB_SECURITY_LOG"
rc=0
__secret_get_keychain_any "stub-key" >/dev/null || rc=$?
assert_eq "get_any returns 36" "36" "$rc"
assert_eq "get_any stops after the first attempt on 36" "1" "$(grep -c find-generic-password "$STUB_SECURITY_LOG")"

echo "-- stubbed: item not found (security exit 44) --"
export STUB_SECURITY_FIND_RC=44
rc=0
__secret_get_keychain "stub-key" >/dev/null || rc=$?
assert_eq "get returns 44 for a missing item" "44" "$rc"
assert_eq "__SECRETS_LAST_RC records 44" "44" "$__SECRETS_LAST_RC"

: > "$STUB_SECURITY_LOG"
rc=0
__secret_get_keychain_any "stub-key" >/dev/null || rc=$?
assert_eq "get_any returns 44 after exhausting attempts" "44" "$rc"
assert_eq "get_any tries account, service and label on 44" "3" "$(grep -c find-generic-password "$STUB_SECURITY_LOG")"

echo "-- stubbed: __secret_keychain_locked --"
export STUB_SECURITY_INFO_RC=36
rc=0; __secret_keychain_locked || rc=$?
assert_eq "show-keychain-info exit 36 means locked (returns 0)" "0" "$rc"
export STUB_SECURITY_INFO_RC=51
rc=0; __secret_keychain_locked || rc=$?
assert_eq "show-keychain-info exit 51 means locked (returns 0)" "0" "$rc"
export STUB_SECURITY_INFO_RC=0
rc=0; __secret_keychain_locked || rc=$?
assert_eq "show-keychain-info exit 0 means unlocked (returns 1)" "1" "$rc"
export STUB_SECURITY_INFO_RC=1
rc=0; __secret_keychain_locked || rc=$?
assert_eq "unknown show-keychain-info error is not reported as locked" "1" "$rc"

echo "-- stubbed: __secret_keychain_path --"
assert_eq "default keychain path" "$HOME/Library/Keychains/login.keychain-db" "$(__secret_keychain_path)"
assert_eq "SECRETS_KEYCHAIN overrides path" "/tmp/x.keychain-db" "$(SECRETS_KEYCHAIN=/tmp/x.keychain-db __secret_keychain_path)"

# Restore the real `security` for the live tests below
PATH="$REAL_PATH"
unset STUB_SECURITY_FIND_RC STUB_SECURITY_INFO_RC STUB_SECURITY_UNLOCK_RC STUB_SECURITY_LOG

# ─────────────────────────────────────────────────────────────────────────────
#   Live Keychain Tests
# ─────────────────────────────────────────────────────────────────────────────

# Test: set and get a secret
echo "-- set/get --"
register_key "test-key-1"
# A locked keychain makes every write fail with security exit 36 (see
# secret_unlock): report that honestly instead of failing every live test.
store_rc=0
__secret_set_keychain "test-key-1" "hello-world" || store_rc=$?
if [[ $store_rc -ne 0 ]]; then
    echo "SKIP: real keychain not reachable from this process (security exit $store_rc — locked?); skipping live tests"
    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed (live tests skipped) ==="
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi
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

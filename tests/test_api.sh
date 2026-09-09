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
STUB_DIR=""

cleanup() {
    # Delete all test entries created during this run
    for key in ${TEST_KEYS+"${TEST_KEYS[@]}"}; do
        secret_delete "$key" &>/dev/null || true
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

# ─────────────────────────────────────────────────────────────────────────────
#   Hermetic Keychain Tests (stubbed `security`, keychain backend forced)
# ─────────────────────────────────────────────────────────────────────────────

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
saved_backend="$__SECRETS_BACKEND"
__SECRETS_BACKEND="keychain"
# On non-macOS the keychain backend was never sourced
declare -f __secret_get_keychain >/dev/null || source "$SCRIPT_DIR/../backends/keychain.sh"
stub_key="stub-key-$$"     # unique so no file-backend fallback can match it

echo "-- secret: keychain locked (security exit 36) --"
export STUB_SECURITY_FIND_RC=36
rc=0
out=$(secret "$stub_key" 2>"$STUB_DIR/stderr") || rc=$?
assert_eq "locked keychain returns exit 2" "2" "$rc"
assert_eq "locked keychain prints nothing on stdout" "" "$out"
assert_contains "locked keychain stderr hints secret_unlock" "run: secret_unlock" "$(cat "$STUB_DIR/stderr")"
assert_contains "locked keychain stderr names the security exit code" "security exit 36" "$(cat "$STUB_DIR/stderr")"
rc=0
out=$(secret -a "$stub_key" 2>"$STUB_DIR/stderr") || rc=$?
assert_eq "locked keychain with -a returns exit 2" "2" "$rc"
assert_contains "locked keychain with -a hints secret_unlock" "run: secret_unlock" "$(cat "$STUB_DIR/stderr")"

echo "-- secret: item not found (security exit 44) --"
export STUB_SECURITY_FIND_RC=44
rc=0
out=$(secret "$stub_key" 2>"$STUB_DIR/stderr") || rc=$?
assert_eq "missing key still returns exit 1" "1" "$rc"
assert_contains "missing key still reports not found" "not found" "$(cat "$STUB_DIR/stderr")"

echo "-- secret_unlock --"
help_output=$(secret_unlock --help 2>&1)
assert_contains "secret_unlock --help contains Usage" "Usage:" "$help_output"

export STUB_SECURITY_INFO_RC=0
rc=0
err=$(secret_unlock 2>&1 >/dev/null) || rc=$?
assert_eq "already unlocked returns 0" "0" "$rc"
assert_contains "already unlocked says so" "already unlocked" "$err"

export STUB_SECURITY_INFO_RC=36
if { : </dev/tty; } 2>/dev/null; then
    # TTY available: the (stubbed) unlock prompt path runs
    export STUB_SECURITY_UNLOCK_RC=0
    : > "$STUB_SECURITY_LOG"
    rc=0
    err=$(secret_unlock 2>&1 >/dev/null) || rc=$?
    assert_eq "locked + TTY: successful unlock returns 0" "0" "$rc"
    assert_contains "locked + TTY: reports unlocked" "keychain unlocked" "$err"
    unlock_call="$(grep '^unlock-keychain' "$STUB_SECURITY_LOG")"
    assert_eq "locked + TTY: unlock targets the keychain path only, never -p" \
        "unlock-keychain $(__secret_keychain_path)" "$unlock_call"
    export STUB_SECURITY_UNLOCK_RC=51
    rc=0
    err=$(secret_unlock 2>&1 >/dev/null) || rc=$?
    assert_eq "locked + TTY: cancelled unlock returns security's exit code" "51" "$rc"
    assert_contains "locked + TTY: reports skipped/failed" "skipped/failed (security exit 51)" "$err"
else
    # No TTY (CI, agent shells): must not attempt to prompt
    rc=0
    err=$(secret_unlock 2>&1 >/dev/null) || rc=$?
    assert_eq "locked + no TTY returns 2" "2" "$rc"
    assert_contains "locked + no TTY explains" "no TTY" "$err"
fi

__SECRETS_BACKEND="file"
rc=0
err=$(secret_unlock 2>&1 >/dev/null) || rc=$?
assert_eq "non-keychain backend returns 0" "0" "$rc"
assert_contains "non-keychain backend explains" "only applicable to the keychain backend" "$err"

# Restore the real backend and `security`
__SECRETS_BACKEND="$saved_backend"
PATH="$REAL_PATH"
unset STUB_SECURITY_FIND_RC STUB_SECURITY_INFO_RC STUB_SECURITY_UNLOCK_RC STUB_SECURITY_LOG

# ─────────────────────────────────────────────────────────────────────────────
#   Live Store Tests
# ─────────────────────────────────────────────────────────────────────────────

# Mutation tests need a reachable store: a locked macOS keychain makes every
# write fail with security exit 36 (see secret_unlock).
store_rc=0
if [[ "$__SECRETS_BACKEND" != "file" ]]; then
    register_key "api-test-key-1"
    secret_set "api-test-key-1" "test-value-42" || store_rc=$?
fi

# Skip set/get/delete/list tests if backend is file-only (read-only)
if [[ "$__SECRETS_BACKEND" == "file" ]]; then
    echo "SKIP: File backend is read-only; skipping set/get/delete/list mutation tests"
    echo ""
elif [[ $store_rc -ne 0 ]]; then
    echo "SKIP: secret store not reachable from this process (secret_set exit $store_rc — keychain locked?); skipping mutation tests"
    echo ""
else

    # Test: secret_set then secret returns value
    echo "-- secret_set + secret (get) --"
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

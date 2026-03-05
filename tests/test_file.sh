#!/bin/bash
# test_file.sh - Tests for file fallback backend
#
# Creates a temporary file with test KEY=VALUE entries.
# Cleans up on exit.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#   Test Setup
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../backends/file.sh
source "$SCRIPT_DIR/../backends/file.sh"

PASS_COUNT=0
FAIL_COUNT=0

# Create a temp file with test data
TEST_FILE="$(mktemp)"
SECRETS_FILE_PATH="$TEST_FILE"

cleanup() {
    rm -f "$TEST_FILE"
}
trap cleanup EXIT

# Populate the test file
cat > "$TEST_FILE" <<'TESTDATA'
# This is a comment
API_KEY=sk-test-12345

DB_HOST=localhost
DB_PORT=5432
# Another comment
EMPTY_VALUE=
SPECIAL_CHARS=p@$$w0rd!#%^&*()
TESTDATA

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

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== File Fallback Backend Tests ==="
echo "  Test file: $TEST_FILE"
echo ""

# Test: get existing key
echo "-- get existing key --"
result=$(__secret_get_file "API_KEY")
assert_eq "get API_KEY returns correct value" "sk-test-12345" "$result"

# Test: get another existing key
echo "-- get another key --"
result=$(__secret_get_file "DB_HOST")
assert_eq "get DB_HOST returns correct value" "localhost" "$result"

# Test: get nonexistent key
echo "-- get nonexistent key --"
result=$(__secret_get_file "NONEXISTENT_KEY" || true)
assert_empty "nonexistent key returns empty" "$result"

# Test: comments are skipped (not returned as keys)
echo "-- comments skipped --"
list_output=$(__secret_list_file)
if echo "$list_output" | grep -q "^#"; then
    echo "  FAIL: comments should not appear in list"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: comments are skipped in list"
    (( PASS_COUNT++ )) || true
fi

# Test: blank lines are skipped
echo "-- blank lines skipped --"
line_count=$(echo "$list_output" | grep -c "^$" || true)
if [[ "$line_count" -eq 0 ]]; then
    echo "  PASS: blank lines are skipped in list"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: blank lines should not appear in list ($line_count found)"
    (( FAIL_COUNT++ )) || true
fi

# Test: list returns all keys
echo "-- list all keys --"
expected_keys="API_KEY DB_HOST DB_PORT EMPTY_VALUE SPECIAL_CHARS"
actual_keys=$(echo "$list_output" | tr '\n' ' ' | sed 's/ $//')
assert_eq "list returns all keys" "$expected_keys" "$actual_keys"

# Test: empty value is handled
echo "-- empty value --"
result=$(__secret_get_file "EMPTY_VALUE")
assert_eq "empty value returns empty string" "" "$result"

# Test: special characters in values
echo "-- special characters --"
result=$(__secret_get_file "SPECIAL_CHARS")
assert_eq "special characters preserved" 'p@$$w0rd!#%^&*()' "$result"

# Test: __secrets_file returns the configured path
echo "-- secrets file path --"
file_path=$(__secrets_file)
assert_eq "secrets file path matches SECRETS_FILE_PATH" "$TEST_FILE" "$file_path"

# ─────────────────────────────────────────────────────────────────────────────
#   Results
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

#!/bin/bash
# test_doctor.sh - Tests for bin/secrets-doctor
#
# Uses a stub library and a stub exports file so no real secret store is
# ever touched and no cleanup is needed. Also asserts the leak-proof
# property: probed values must never appear on stdout, stderr, or in a
# bash -x trace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$SCRIPT_DIR/../bin/secrets-doctor"

PASS_COUNT=0
FAIL_COUNT=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
#   Test Helpers
# ─────────────────────────────────────────────────────────────────────────────

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (expected '$expected', got '$actual')"
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
        echo "  FAIL: $test_name (output leaked '$needle')"
        ((FAIL_COUNT++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   Stub library + exports file
# ─────────────────────────────────────────────────────────────────────────────

SECRET_VALUE="stub-value-abcdef-123456"

cat > "$TMPDIR_TEST/stub-lib.sh" << EOF
secret() {
    case "\$1" in
        GOODKEY)  printf '%s' "$SECRET_VALUE" ;;
        EMPTYKEY) printf '' ;;
        CTRLKEY)  printf 'ab\ncd' ;;
    esac
}
secret_list() { printf 'GOODKEY\nEMPTYKEY\nCTRLKEY\nORPHANKEY\n'; }
EOF

cat > "$TMPDIR_TEST/stub-exports.sh" << 'EOF'
export GOODKEY="$(secret GOODKEY 2>/dev/null)"
export EMPTYKEY="$(secret EMPTYKEY 2>/dev/null)"
export CTRLKEY="$(secret CTRLKEY 2>/dev/null)"
export ALIASKEY="$GOODKEY"
EOF

run_doctor() {
    SECRETS_LIB="$TMPDIR_TEST/stub-lib.sh" \
    SECRETS_EXPORTS_FILE="$TMPDIR_TEST/stub-exports.sh" \
    GOODKEY="$SECRET_VALUE" ALIASKEY="$SECRET_VALUE" \
        "$DOCTOR" "$@" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "Running secrets-doctor tests..."

# Presence mode: healthy key
out="$(run_doctor GOODKEY)"; rc=$?
assert_eq "healthy key exits 0" "0" "$rc"
assert_contains "healthy key STORE ok" "$out" "ok"
assert_contains "healthy key ENV set" "$out" "set"

# Presence mode: broken env
out="$(run_doctor EMPTYKEY)" && rc=0 || rc=$?
assert_eq "empty env exits 1" "1" "$rc"
assert_contains "empty env reported MISSING" "$out" "MISSING"

# Derived alias: store n/a, not a failure
out="$(run_doctor ALIASKEY)"; rc=$?
assert_eq "derived alias exits 0" "0" "$rc"
assert_contains "derived alias STORE n/a" "$out" "n/a"
assert_contains "derived alias marked derived" "$out" "(derived)"

# Prefix expansion
out="$(run_doctor GOOD)"; rc=$?
assert_contains "prefix expands to GOODKEY" "$out" "GOODKEY"

# Unknown key
out="$(run_doctor NOSUCHKEY)" && rc=0 || rc=$?
assert_eq "unknown key exits 1" "1" "$rc"

# Probe mode: empty and ctrl-char detection
out="$(run_doctor --probe EMPTYKEY CTRLKEY GOODKEY)" && rc=0 || rc=$?
assert_eq "probe with broken keys exits 1" "1" "$rc"
assert_contains "probe flags EMPTY" "$out" "EMPTY"
assert_contains "probe flags ctrl-chars" "$out" "ctrl-chars"
assert_contains "probe passes good key" "$out" "ok*"

# Match mode: pass and fail
out="$(run_doctor --match '^stub-value-' GOODKEY)"; rc=$?
assert_eq "match pass exits 0" "0" "$rc"
out="$(run_doctor --match '^NEVER' GOODKEY)" && rc=0 || rc=$?
assert_eq "match fail exits 1" "1" "$rc"
assert_contains "match fail reported" "$out" "no-match"

# Leak-proofing: value never on stdout/stderr, even probed
out="$(run_doctor --probe --match '^stub' GOODKEY EMPTYKEY CTRLKEY)" || true
assert_not_contains "no value leak in probe output" "$out" "$SECRET_VALUE"

# Leak-proofing: value never in a bash -x trace
trace="$(SECRETS_LIB="$TMPDIR_TEST/stub-lib.sh" \
    SECRETS_EXPORTS_FILE="$TMPDIR_TEST/stub-exports.sh" \
    bash -x "$DOCTOR" --probe GOODKEY 2>&1 >/dev/null)" || true
assert_not_contains "no value leak in bash -x trace" "$trace" "$SECRET_VALUE"

# Unknown option
run_doctor --bogus >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "unknown option exits 2" "2" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
#   Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]

#!/bin/bash
# test_keychain.sh - Tests for macOS Keychain backend
#
# The hermetic tests stub `security` and run on any OS; the live tests need
# macOS and its real `security`, use a unique test namespace to avoid
# polluting real secrets, and clean up their entries on exit.

set -euo pipefail

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
# appended to STUB_SECURITY_LOG so attempt counts can be asserted. In
# interactive mode (-q -i) it saves its stdin to STUB_SECURITY_STDIN.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/security" << 'EOF'
#!/bin/bash
[[ -n "${STUB_SECURITY_LOG:-}" ]] && echo "$*" >> "$STUB_SECURITY_LOG"
if [[ "$*" == "-q -i" ]]; then
    cat > "${STUB_SECURITY_STDIN:-/dev/null}"
    exit "${STUB_SECURITY_ADD_RC:-0}"
fi
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

# Port of split_line() from Apple's SecurityTool/macOS/security.c: how
# `security -i` turns one input line into argv. Prints one arg per line,
# each prefixed with "|" so empty args stay visible.
split_line() {
    local line="$1" state=SKIP_WS quote="" arg="" ch i
    for (( i = 0; i < ${#line}; i++ )); do
        ch="${line:i:1}"
        case "$state" in
            SKIP_WS)
                [[ "$ch" == [[:space:]] ]] && continue
                if [[ "$ch" == '"' || "$ch" == "'" ]]; then
                    quote="$ch"; state=QUOTED; arg=""; continue
                fi
                state=ARG; arg="" ;;
        esac
        case "$state" in
            ARG)
                if [[ "$ch" == "\\" ]]; then state=ARG_ESC
                elif [[ "$ch" == [[:space:]] ]]; then printf '|%s\n' "$arg"; state=SKIP_WS
                else arg+="$ch"; fi ;;
            QUOTED)
                if [[ "$ch" == "\\" ]]; then state=QUOTED_ESC
                elif [[ "$ch" == "$quote" ]]; then printf '|%s\n' "$arg"; state=SKIP_WS
                else arg+="$ch"; fi ;;
            ARG_ESC)    arg+="$ch"; state=ARG ;;
            QUOTED_ESC) arg+="$ch"; state=QUOTED ;;
        esac
    done
    [[ "$state" != SKIP_WS ]] && printf '|%s\n' "$arg"
    return 0
}

# What `security -i` must see for: add-generic-password -U -a K -s S -l K -w V
expected_args() {
    printf '|%s\n' add-generic-password -U -a "$1" -s "$SECRETS_SERVICE" -l "$1" -w "$2"
}

echo "-- split_line port matches security.c --"
assert_eq "escaped quote and backslash inside quotes" '|a"b\' "$(split_line '"a\"b\\"')"
assert_eq "unquoted args split on whitespace" $'|x\n|y' "$(split_line ' x   y ')"
assert_eq "an unescaped inner quote ends the arg early" $'|a\n|b"' "$(split_line '"a"b"')"

export STUB_SECURITY_STDIN="$STUB_DIR/stdin"

echo "-- stubbed: set sends the value on stdin, never in argv --"
tricky_value='a "b" \c '"'"'d'"'"' $HOME `x` é  \\" end\'
for case_key in "stub-key" 'key with "quotes" \ and spaces'; do
    : > "$STUB_SECURITY_LOG"; rm -f "$STUB_SECURITY_STDIN"
    rc=0
    __secret_set_keychain "$case_key" "$tricky_value" || rc=$?
    assert_eq "set returns 0 [$case_key]" "0" "$rc"
    assert_eq "security ran once, as 'security -q -i' [$case_key]" "-q -i" "$(cat "$STUB_SECURITY_LOG")"
    if grep -qF -- "$tricky_value" "$STUB_SECURITY_LOG"; then
        assert_eq "value absent from security's argv [$case_key]" "absent" "present"
    else
        assert_eq "value absent from security's argv [$case_key]" "absent" "absent"
    fi
    assert_eq "stdin is exactly one newline-terminated line [$case_key]" "1" "$(wc -l < "$STUB_SECURITY_STDIN" | tr -d ' ')"
    assert_eq "stdin ends with a newline [$case_key]" "0a" "$(tail -c 1 "$STUB_SECURITY_STDIN" | od -An -tx1 | tr -d ' \n')"
    assert_eq "split_line recovers key, service and value unchanged [$case_key]" \
        "$(expected_args "$case_key" "$tricky_value")" \
        "$(split_line "$(head -n 1 "$STUB_SECURITY_STDIN")")"
done

echo "-- stubbed: set passes security's exit code through --"
export STUB_SECURITY_ADD_RC=36
rc=0
__secret_set_keychain "stub-key" "v" || rc=$?
assert_eq "set returns security's exit code 36 unchanged" "36" "$rc"
unset STUB_SECURITY_ADD_RC

echo "-- stubbed: set refuses what security -i would mangle --"
: > "$STUB_SECURITY_LOG"
rc=0
err=$(__secret_set_keychain "stub-key" $'line1\nline2' 2>&1) || rc=$?
assert_eq "newline in value is refused with status 2" "2" "$rc"
assert_not_empty "newline refusal explains itself" "$err"
if [[ "$err" == *line2* ]]; then
    assert_eq "newline refusal does not echo the value" "absent" "present"
else
    assert_eq "newline refusal does not echo the value" "absent" "absent"
fi
assert_eq "newline value never reaches security" "0" "$(wc -l < "$STUB_SECURITY_LOG" | tr -d ' ')"

# The line for key k is: add-generic-password -U -a "k" -s "<svc>" -l "k" -w "<value>"
line_overhead=$(( ${#SECRETS_SERVICE} + 49 ))
assert_eq "line overhead matches the real command line" \
    "$(( line_overhead + 3 ))" \
    "$(printf 'add-generic-password -U -a "k" -s "%s" -l "k" -w "abc"' "$SECRETS_SERVICE" | wc -c | tr -d ' ')"
max_value=$(printf 'v%.0s' $(seq 1 $(( __SECRETS_KEYCHAIN_MAX_LINE - line_overhead ))))
rc=0
__secret_set_keychain "k" "$max_value" 2>/dev/null || rc=$?
assert_eq "a line of exactly $__SECRETS_KEYCHAIN_MAX_LINE bytes is accepted" "0" "$rc"
: > "$STUB_SECURITY_LOG"
rc=0
__secret_set_keychain "k" "${max_value}v" 2>/dev/null || rc=$?
assert_eq "one byte more is refused with status 2" "2" "$rc"
rc=0
__secret_set_keychain "k" "${max_value:1}é" 2>/dev/null || rc=$?
assert_eq "the limit counts bytes, not characters (same length, é is 2 bytes)" "2" "$rc"
assert_eq "over-long values never reach security" "0" "$(wc -l < "$STUB_SECURITY_LOG" | tr -d ' ')"

# Restore the real `security` for the live tests below
PATH="$REAL_PATH"
unset STUB_SECURITY_FIND_RC STUB_SECURITY_INFO_RC STUB_SECURITY_UNLOCK_RC STUB_SECURITY_LOG STUB_SECURITY_STDIN

# ─────────────────────────────────────────────────────────────────────────────
#   Live Keychain Tests (macOS only)
# ─────────────────────────────────────────────────────────────────────────────

finish() {
    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed${1:+ ($1)} ==="
    [[ "$FAIL_COUNT" -eq 0 ]]
}

if [[ "$OSTYPE" != darwin* ]]; then
    echo "SKIP: live tests need macOS (OSTYPE=$OSTYPE)"
    finish "live tests skipped"; exit
fi
if ! command -v security &>/dev/null; then
    echo "SKIP: live tests need the 'security' command"
    finish "live tests skipped"; exit
fi

# Test: set and get a secret
echo "-- set/get --"
register_key "test-key-1"
# A locked keychain makes every write fail with security exit 36 (see
# secret_unlock): report that honestly instead of failing every live test.
store_rc=0
__secret_set_keychain "test-key-1" "hello-world" || store_rc=$?
if [[ $store_rc -ne 0 ]]; then
    echo "SKIP: real keychain not reachable from this process (security exit $store_rc — locked?); skipping live tests"
    finish "live tests skipped"; exit
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

# Test: quotes, backslashes and spaces survive `security -i`'s line parser
echo "-- quotes and backslashes --"
register_key "test-quoting"
quoting_value='a "b" \c '"'"'d'"'"'  \\" end\'
__secret_set_keychain "test-quoting" "$quoting_value"
result=$(__secret_get_keychain "test-quoting")
assert_eq "quotes, backslashes and spaces preserved" "$quoting_value" "$result"

# Test: the value never reaches argv. A shim in front of the real `security`
# records the exact argv it was given (deterministic); a ps sampler watches
# the whole process table meanwhile (the leak the card describes).
echo "-- value never in argv --"
register_key "test-argv"
argv_marker="argv-marker-$$-$RANDOM"
SHIM_DIR="$(mktemp -d)"
cat > "$SHIM_DIR/security" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SHIM_DIR/argv.log"
exec $(command -v security) "\$@"
EOF
chmod +x "$SHIM_DIR/security"
: > "$SHIM_DIR/ps.log"
touch "$SHIM_DIR/sampling"
( while [[ -e "$SHIM_DIR/sampling" ]]; do ps -axww -o args= >> "$SHIM_DIR/ps.log" 2>/dev/null; done ) &
sampler_pid=$!
# Positive control: a process with the marker in argv must be caught. The
# trailing ':' stops bash from exec'ing sleep, which would drop the marker.
bash -c 'sleep 1; :' "control-$argv_marker" &
wait $!
for _ in 1 2 3 4 5; do
    PATH="$SHIM_DIR:$PATH" __secret_set_keychain "test-argv" "$argv_marker"
done
rm -f "$SHIM_DIR/sampling"
wait "$sampler_pid" 2>/dev/null || true
assert_eq "set calls security as 'security -q -i' only" "-q -i" "$(sort -u "$SHIM_DIR/argv.log")"
assert_eq "value absent from the argv security received" "0" "$(grep -cF -- "$argv_marker" "$SHIM_DIR/argv.log" || true)"
assert_not_empty "ps sampler sees argv (positive control)" "$(grep -F -- "control-$argv_marker" "$SHIM_DIR/ps.log" || true)"
assert_empty "value absent from ps during writes" "$(grep -F -- "$argv_marker" "$SHIM_DIR/ps.log" | grep -vF -- "control-$argv_marker" || true)"
assert_eq "value stored through the shim reads back" "$argv_marker" "$(__secret_get_keychain "test-argv")"
rm -rf "$SHIM_DIR"

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

finish

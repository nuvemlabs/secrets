#!/bin/bash
# test_credmanager.sh - Tests for Windows Credential Manager backend
#
# The hermetic tests stub PowerShell and run on any OS; the live tests need
# PowerShell with the CredentialManager module, use a unique test namespace
# to avoid polluting real credentials, and clean up their entries on exit.

set -euo pipefail

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
STUB_DIR=""
LIVE=0

cleanup() {
    # Delete all test entries created during this run (live tests only)
    if [[ "$LIVE" -eq 1 ]]; then
        for key in ${TEST_KEYS+"${TEST_KEYS[@]}"}; do
            __secret_delete_credmanager "$key" || true
        done
    fi
    [[ -n "${STUB_DIR:-}" ]] && rm -rf "$STUB_DIR"
    return 0
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
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#   Hermetic Tests (stubbed PowerShell — never touches a real credential store)
# ─────────────────────────────────────────────────────────────────────────────

# The stub stands in for powershell.exe. Each call appends its argv (one arg
# per line, then a "--" line) to STUB_PS_ARGV, the service and key it got in
# the environment to STUB_PS_ENV, and saves its stdin to STUB_PS_STDIN. It
# keeps credentials as files in STUB_PS_STORE, picking the operation from the
# cmdlet named in the script. STUB_PS_SET_RC makes a set fail with that code.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/powershell" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" -- >> "$STUB_PS_ARGV"
printf 'service=%s\nkey=%s\nwslenv=%s\n' "${SECRETS_CM_SERVICE-<unset>}" "${SECRETS_CM_KEY-<unset>}" "${WSLENV-}" > "$STUB_PS_ENV"
script="${*: -1}"
target_file() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
target="$SECRETS_CM_SERVICE:$SECRETS_CM_KEY"
case "$script" in
    *New-StoredCredential*)
        cat > "$STUB_PS_STDIN"
        [[ -n "${STUB_PS_SET_RC:-}" ]] && { echo "New-StoredCredential: stub failure" >&2; exit "$STUB_PS_SET_RC"; }
        cp "$STUB_PS_STDIN" "$STUB_PS_STORE/$(target_file "$target")" ;;
    *Remove-StoredCredential*)
        rm -f "$STUB_PS_STORE/$(target_file "$target")" ;;
    *AsCredentialObject*)
        for f in "$STUB_PS_STORE"/*; do
            [[ -e "$f" ]] || continue
            name=$(basename "$f" | sed 's/../\\x&/g')
            printf '%b\r\n' "$name"
        done ;;
    *Get-StoredCredential*)
        f="$STUB_PS_STORE/$(target_file "$target")"
        [[ -e "$f" ]] && { cat "$f"; printf '\r\n'; } ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/powershell"
# A backend that forgets to pipe the value must read nothing, not hang
exec < /dev/null
mkdir "$STUB_DIR/store"
export SECRETS_POWERSHELL="$STUB_DIR/powershell"
export STUB_PS_ARGV="$STUB_DIR/argv" STUB_PS_ENV="$STUB_DIR/env"
export STUB_PS_STDIN="$STUB_DIR/stdin" STUB_PS_STORE="$STUB_DIR/store"

value_in_argv() { grep -qF -- "$1" "$STUB_PS_ARGV"; }

echo "-- stubbed: set sends the value on stdin, never in argv --"
tricky_value="it's a \"quoted\" \$(touch pwned) \`x\` \$env:PATH back\\slash \\\\ end'"
for case_key in "stub-key" "key'; Remove-Item C:\\ -Recurse; '"; do
    : > "$STUB_PS_ARGV"; rm -f "$STUB_PS_STDIN"
    rc=0
    __secret_set_credmanager "$case_key" "$tricky_value" || rc=$?
    assert_eq "set returns 0 [$case_key]" "0" "$rc"
    if value_in_argv "$tricky_value"; then
        assert_eq "value absent from PowerShell's argv [$case_key]" "absent" "present"
    else
        assert_eq "value absent from PowerShell's argv [$case_key]" "absent" "absent"
    fi
    if grep -qF -- "$case_key" "$STUB_PS_ARGV"; then
        assert_eq "key not spliced into the script [$case_key]" "absent" "present"
    else
        assert_eq "key not spliced into the script [$case_key]" "absent" "absent"
    fi
    if grep -qF -- "$SECRETS_SERVICE" "$STUB_PS_ARGV"; then
        assert_eq "service not spliced into the script [$case_key]" "absent" "present"
    else
        assert_eq "service not spliced into the script [$case_key]" "absent" "absent"
    fi
    assert_eq "stdin is exactly the value, byte for byte [$case_key]" \
        "$(printf '%s' "$tricky_value" | od -An -tx1 | tr -d ' \n')" "$(od -An -tx1 < "$STUB_PS_STDIN" | tr -d ' \n')"
    assert_eq "key and service arrive verbatim in the environment [$case_key]" \
        "$SECRETS_SERVICE|$case_key" \
        "$(sed -n 's/^service=//p' "$STUB_PS_ENV")|$(sed -n 's/^key=//p' "$STUB_PS_ENV")"
    assert_eq "value round-trips through get unchanged [$case_key]" "$tricky_value" "$(__secret_get_credmanager "$case_key")"
done

echo "-- stubbed: WSL gets the names, not the values --"
WSLENV="EXISTING/p" __secret_set_credmanager "stub-key" "v"
assert_eq "WSLENV keeps the caller's entries and adds the two names" \
    "EXISTING/p:SECRETS_CM_SERVICE:SECRETS_CM_KEY" "$(sed -n 's/^wslenv=//p' "$STUB_PS_ENV")"

echo "-- stubbed: get, delete and list pass names the same way --"
for op in get delete list; do
    : > "$STUB_PS_ARGV"
    case "$op" in
        get)    __secret_get_credmanager "stub-key" >/dev/null ;;
        delete) __secret_delete_credmanager "stub-key" ;;
        list)   __secret_list_credmanager >/dev/null ;;
    esac
    if grep -qF -- "$SECRETS_SERVICE" "$STUB_PS_ARGV"; then
        assert_eq "$op: service not spliced into the script" "absent" "present"
    else
        assert_eq "$op: service not spliced into the script" "absent" "absent"
    fi
    assert_eq "$op: service arrives in the environment" "$SECRETS_SERVICE" "$(sed -n 's/^service=//p' "$STUB_PS_ENV")"
done
assert_empty "deleted key reads back empty" "$(__secret_get_credmanager "stub-key")"

echo "-- stubbed: set returns PowerShell's failure --"
rc=0
# Without pipefail, as in an interactive shell: a pipe must not hide the code
err=$(set +o pipefail; STUB_PS_SET_RC=1 __secret_set_credmanager "stub-key" "secret-value-$$" 2>&1) || rc=$?
assert_eq "failed set returns PowerShell's exit code 1" "1" "$rc"
assert_eq "PowerShell's error stays visible" "New-StoredCredential: stub failure" "$err"

unset SECRETS_POWERSHELL STUB_PS_ARGV STUB_PS_ENV STUB_PS_STDIN STUB_PS_STORE

# ─────────────────────────────────────────────────────────────────────────────
#   Live Credential Manager Tests (PowerShell + CredentialManager module)
# ─────────────────────────────────────────────────────────────────────────────

finish() {
    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed${1:+ ($1)} ==="
    [[ "$FAIL_COUNT" -eq 0 ]]
}

# Detect PowerShell binary
if command -v powershell.exe &>/dev/null; then
    SECRETS_POWERSHELL="powershell.exe"
elif command -v pwsh &>/dev/null; then
    SECRETS_POWERSHELL="pwsh"
else
    echo "SKIP: live tests need 'powershell.exe' or 'pwsh'"
    finish "live tests skipped"; exit
fi
export SECRETS_POWERSHELL

# Verify CredentialManager module is available (check for actual output, not just exit code)
module_check=$("$SECRETS_POWERSHELL" -NoProfile -NonInteractive -Command "Get-Module -ListAvailable CredentialManager" 2>/dev/null | tr -d '\r\n ')
if [[ -z "$module_check" ]]; then
    echo "SKIP: live tests need the CredentialManager PowerShell module"
    finish "live tests skipped"; exit
fi
LIVE=1
echo "  PowerShell binary: $SECRETS_POWERSHELL"

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

# Test: quotes, $(...) and backslashes reach the store unchanged
echo "-- quotes and backslashes --"
register_key "test-quoting"
quoting_value="it's \"q\" \$(x) \$env:PATH back\\slash"
__secret_set_credmanager "test-quoting" "$quoting_value"
result=$(__secret_get_credmanager "test-quoting")
assert_eq "quotes, \$(...) and backslashes preserved" "$quoting_value" "$result"

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

finish

#!/bin/bash
# test_backup.sh - Tests for bin/secrets-backup
#
# Hermetic: a stub library keeps secrets as files and a stub `bw` keeps the
# vault as JSON, so neither the real store nor a real vault is touched. Also
# asserts that values never reach stdout, stderr or any bw argv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP="$SCRIPT_DIR/../bin/secrets-backup"

PASS_COUNT=0
FAIL_COUNT=0

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

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
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (missing '$needle' in: $haystack)"
        ((FAIL_COUNT++)) || true
    fi
}

assert_not_contains() {
    local test_name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (found '$needle')"
        ((FAIL_COUNT++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   Stubs
# ─────────────────────────────────────────────────────────────────────────────

export STORE="$T/store" BW_STATE="$T/vault"
mkdir -p "$STORE" "$BW_STATE" "$T/bin"

# Library stub: $STORE/<service>/<key> holds the value
cat > "$T/lib.sh" <<'EOF'
: "${SECRETS_SERVICE:=secrets}"
secret_get() { [[ -f "$STORE/$SECRETS_SERVICE/$1" ]] && cat "$STORE/$SECRETS_SERVICE/$1"; }
secret_set() { mkdir -p "$STORE/$SECRETS_SERVICE"; printf '%s' "$2" > "$STORE/$SECRETS_SERVICE/$1"; }
secret_list() {
    if [[ "${1:-}" == -a ]]; then
        (cd "$STORE" && for f in */*; do [[ -f "$f" ]] && echo "${f%%/*}:${f#*/}"; done)
    else
        [[ -d "$STORE/$SECRETS_SERVICE" ]] && ls "$STORE/$SECRETS_SERVICE"
    fi
    return 0
}
EOF

# bw stub: folders.json and items.json are the vault; every argv is logged
cat > "$T/bin/bw" <<'EOF'
#!/bin/bash
echo "$*" >> "$BW_STATE/argv.log"
F="$BW_STATE/folders.json" I="$BW_STATE/items.json"
[[ -f "$F" ]] || echo '[]' > "$F"
[[ -f "$I" ]] || echo '[]' > "$I"
new_id() { echo "id-$RANDOM$RANDOM"; }
case "$1 ${2:-}" in
    "status "*)        echo "{\"status\":\"${BW_STUB_STATUS:-unlocked}\"}" ;;
    "sync "*)          echo "Syncing complete." ;;
    "encode "*)        base64 -w0 ;;
    "list folders")    cat "$F" ;;
    "list items")      jq --arg f "$4" '[.[] | select(.folderId == $f)]' "$I" ;;
    "create folder")   base64 -d | jq --arg id "$(new_id)" '. + {id: $id}' > "$BW_STATE/new"
                       jq --slurpfile n "$BW_STATE/new" '. + $n' "$F" > "$F.tmp" && mv "$F.tmp" "$F" ;;
    "create item")     base64 -d | jq --arg id "$(new_id)" '. + {id: $id}' > "$BW_STATE/new"
                       jq --slurpfile n "$BW_STATE/new" '. + $n' "$I" > "$I.tmp" && mv "$I.tmp" "$I" ;;
    "edit item")       base64 -d > "$BW_STATE/new"
                       jq --arg id "$3" --slurpfile n "$BW_STATE/new" 'map(if .id == $id then $n[0] else . end)' "$I" > "$I.tmp" && mv "$I.tmp" "$I" ;;
    *)                 echo "stub bw: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/bw"

export PATH="$T/bin:$PATH" SECRETS_LIB="$T/lib.sh" SECRETS_SERVICE=svc

run() { "$BACKUP" "$@" 2>&1; }
vault_value() {  # vault_value FOLDER KEY
    local fid
    fid=$(jq -r --arg n "$1" '.[] | select(.name == $n) | .id' "$BW_STATE/folders.json")
    jq -j --arg f "$fid" --arg k "$2" '.[] | select(.folderId == $f and .name == $k) | .login.password' "$BW_STATE/items.json"
}
item_count() { jq length "$BW_STATE/items.json"; }

SECRET_A='va1ue-A "quoted" \ back'
SECRET_B='value-B'
mkdir -p "$STORE/svc" "$STORE/bridge:proj"
printf '%s' "$SECRET_A" > "$STORE/svc/KEY_A"
printf '%s' "$SECRET_B" > "$STORE/svc/KEY_B"
printf '%s' "bridge-value" > "$STORE/bridge:proj/KEY_C"

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== secrets-backup Tests ==="

echo "-- usage --"
rc=0; "$BACKUP" >/dev/null 2>&1 || rc=$?
assert_eq "no mode exits 2" "2" "$rc"
rc=0; "$BACKUP" push --force >/dev/null 2>&1 || rc=$?
assert_eq "--force on push exits 2" "2" "$rc"

echo "-- locked vault --"
rc=0; out=$(BW_STUB_STATUS=locked run push) || rc=$?
assert_eq "locked vault exits 1" "1" "$rc"
assert_contains "locked vault prints the unlock hint" "bw unlock --raw" "$out"

echo "-- push --dry-run --"
out=$(run push -n)
assert_contains "dry run reports what it would create" "created    KEY_A" "$out"
assert_eq "dry run creates no item" "0" "$(item_count)"
assert_eq "dry run creates no folder" "0" "$(jq length "$BW_STATE/folders.json")"

echo "-- push --"
out=$(run push)
assert_contains "push reports counts" "created 2, updated 0, unchanged 0" "$out"
assert_eq "folder secrets/svc exists" "1" "$(jq '[.[] | select(.name == "secrets/svc")] | length' "$BW_STATE/folders.json")"
assert_eq "KEY_A value is backed up verbatim" "$SECRET_A" "$(vault_value secrets/svc KEY_A)"
assert_eq "KEY_B value is backed up" "$SECRET_B" "$(vault_value secrets/svc KEY_B)"
assert_eq "items are login items" "1" "$(jq -r '.[0].type' "$BW_STATE/items.json")"
assert_eq "only the current service is pushed" "2" "$(item_count)"

echo "-- push again --"
out=$(run push)
assert_contains "second push changes nothing" "created 0, updated 0, unchanged 2" "$out"

echo "-- push a changed value --"
printf 'rotated' > "$STORE/svc/KEY_B"
out=$(run push)
assert_contains "changed value is updated" "updated    KEY_B" "$out"
assert_eq "vault holds the new value" "rotated" "$(vault_value secrets/svc KEY_B)"
assert_eq "update edits in place, no duplicate" "2" "$(item_count)"

echo "-- push never deletes --"
rm "$STORE/svc/KEY_A"
run push >/dev/null
assert_eq "key gone locally stays in the vault" "$SECRET_A" "$(vault_value secrets/svc KEY_A)"

echo "-- push -a --"
out=$(run push -a)
assert_contains "push -a covers a service with a colon" "bridge:proj -> secrets/bridge:proj" "$out"
assert_eq "colon service backed up" "bridge-value" "$(vault_value secrets/bridge:proj KEY_C)"

echo "-- pull --"
rm -rf "$STORE"; mkdir -p "$STORE"
out=$(run pull)
assert_contains "pull restores into an empty store" "created 2" "$out"
assert_eq "restored KEY_A verbatim" "$SECRET_A" "$(cat "$STORE/svc/KEY_A")"
assert_eq "restored KEY_B" "rotated" "$(cat "$STORE/svc/KEY_B")"
assert_eq "pull without -a leaves other services alone" "no" "$([[ -d "$STORE/bridge:proj" ]] && echo yes || echo no)"

echo "-- pull keeps a differing local value --"
printf 'local-wins' > "$STORE/svc/KEY_B"
out=$(run pull)
assert_contains "differing value is kept and reported" "kept       KEY_B" "$out"
assert_eq "local value untouched" "local-wins" "$(cat "$STORE/svc/KEY_B")"
out=$(run pull -n --force)
assert_eq "dry run with --force changes nothing" "local-wins" "$(cat "$STORE/svc/KEY_B")"
out=$(run pull --force)
assert_contains "--force updates" "updated    KEY_B" "$out"
assert_eq "--force overwrote the local value" "rotated" "$(cat "$STORE/svc/KEY_B")"

echo "-- pull -a --"
out=$(run pull -a)
assert_eq "pull -a restores the colon service" "bridge-value" "$(cat "$STORE/bridge:proj/KEY_C")"

echo "-- pull of a service with no folder --"
out=$(SECRETS_SERVICE=nothing run pull)
assert_contains "missing folder is reported" "no folder secrets/nothing" "$out"

echo "-- leak checks --"
all_out=$(run push -a; run pull -a --force; run push -n)
for v in "$SECRET_A" rotated bridge-value; do
    assert_not_contains "value '$v' never printed" "$all_out" "$v"
    assert_not_contains "value '$v' never in bw argv" "$(cat "$BW_STATE/argv.log")" "$v"
done
assert_not_contains "no base64 payload in bw argv" "$(cat "$BW_STATE/argv.log")" "eyJ"

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ $FAIL_COUNT -eq 0 ]]

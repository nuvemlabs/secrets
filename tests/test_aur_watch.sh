#!/bin/bash
# test_aur_watch.sh - Tests for scripts/aur-registration-watch and install.sh --aur-watch
#
# Hermetic: pages and feeds come from tests/fixtures/aur-watch, state lives in
# a temp dir, and the phone/inbox actions are stubs that append to log files,
# so no network, no ntfy and no Steward message is ever touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/aur-registration-watch"
INSTALLER="$SCRIPT_DIR/../install.sh"
FIXTURES="$SCRIPT_DIR/fixtures/aur-watch"

PASS_COUNT=0
FAIL_COUNT=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# The live watcher, as the installer would resolve it from the caller's env.
# Fingerprinted now and checked at the end: the suite must never touch it.
REAL_UNIT_DIR="${SECRETS_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
REAL_FILES=(
    "$REAL_UNIT_DIR/aur-registration-watch.service"
    "$REAL_UNIT_DIR/aur-registration-watch.timer"
    "${SECRETS_BIN_DIR:-$HOME/.local/bin}/aur-registration-watch"
)
fingerprint() {
    local f
    for f in "$@"; do
        if [[ -e "$f" ]]; then sha256sum "$f"; else echo "absent  $f"; fi
    done
}
REAL_BEFORE="$(fingerprint "${REAL_FILES[@]}")"

# Sandbox every path the installer and watcher derive from the environment,
# so a caller's XDG_* or install overrides can't send writes to the live setup.
export HOME="$TMPDIR_TEST/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME"
unset PREFIX DESTDIR SECRETS_INSTALL_DIR SECRETS_BIN_DIR SECRETS_SYSTEMD_USER_DIR SECRETS_SKIP_SYSTEMCTL
while IFS= read -r var; do unset "$var"; done < <(compgen -e | grep '^AUR_WATCH_' || true)

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

assert_file() {
    local test_name="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $test_name"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $test_name (missing $path)"
        ((FAIL_COUNT++)) || true
    fi
}

# Stub actions: each call appends one line to its log; FAIL_NOTIFY=1 makes the phone stub fail
cat > "$TMPDIR_TEST/stub-notify" <<'EOF'
#!/bin/bash
[[ "${FAIL_NOTIFY:-0}" == "1" ]] && exit 1
echo "$*" >> "$AUR_WATCH_TEST_LOGS/notify.log"
EOF
cat > "$TMPDIR_TEST/stub-inbox" <<'EOF'
#!/bin/bash
echo "$*" | tr '\n' ' ' >> "$AUR_WATCH_TEST_LOGS/inbox.log"
echo >> "$AUR_WATCH_TEST_LOGS/inbox.log"
EOF
chmod +x "$TMPDIR_TEST/stub-notify" "$TMPDIR_TEST/stub-inbox"

# new_case NAME: fresh state dir and empty action logs
new_case() {
    CASE_DIR="$TMPDIR_TEST/$1"
    mkdir -p "$CASE_DIR/state" "$CASE_DIR/logs"
    : > "$CASE_DIR/logs/notify.log"
    : > "$CASE_DIR/logs/inbox.log"
}

# watch PAGE STATUS NEWS LIST [args...]: one run against fixtures
watch() {
    local page="$1" status="$2" news="$3" list="$4"
    shift 4
    AUR_WATCH_STATE_DIR="$CASE_DIR/state" \
    AUR_WATCH_TEST_LOGS="$CASE_DIR/logs" \
    AUR_WATCH_NOTIFY_CMD="$TMPDIR_TEST/stub-notify" \
    AUR_WATCH_INBOX_CMD="$TMPDIR_TEST/stub-inbox" \
    AUR_WATCH_PAGE_FILE="$FIXTURES/$page" \
    AUR_WATCH_PAGE_STATUS="$status" \
    AUR_WATCH_NEWS_FILE="$FIXTURES/$news" \
    AUR_WATCH_LIST_FILE="$FIXTURES/$list" \
        python3 "$WATCH" "$@"
}

notify_count() { wc -l < "$CASE_DIR/logs/notify.log" | tr -d ' '; }
inbox_count() { wc -l < "$CASE_DIR/logs/inbox.log" | tr -d ' '; }

# ─────────────────────────────────────────────────────────────────────────────
#   Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== aur-registration-watch Tests ==="

echo "-- classify: hard rules --"
classify() { python3 "$WATCH" --classify "$FIXTURES/$1" --status "$2" | cut -d' ' -f1; }
assert_eq "open form on 200 is OPEN" "OPEN" "$(classify open-200.html 200)"
assert_eq "live closed page (503) is CLOSED" "CLOSED" "$(classify closed-503.html 503)"
assert_eq "closed notice on 200 is CLOSED" "CLOSED" "$(classify closed-503.html 200)"
assert_eq "Anubis bot check is UNKNOWN" "UNKNOWN" "$(classify anubis-challenge.html 200)"
assert_eq "200 without form or notice is UNKNOWN" "UNKNOWN" "$(classify no-form-200.html 200)"
assert_eq "form on a 500 is UNKNOWN" "UNKNOWN" "$(classify open-200.html 500)"

echo "-- closed: first run checks the page and sends nothing --"
new_case closed
out="$(watch closed-503.html 503 news.xml list.xml)"
assert_contains "first run reads CLOSED" "$out" "page: CLOSED"
assert_eq "closed: no phone alert" "0" "$(notify_count)"
assert_eq "closed: no inbox message" "0" "$(inbox_count)"
out="$(watch closed-503.html 503 news.xml list.xml)"
assert_contains "second run leaves the page alone" "$out" "next check when due or on a lead"

echo "-- open: one alert per channel, never repeated while open --"
new_case open
watch closed-503.html 503 news.xml list.xml >/dev/null
out="$(watch open-200.html 200 news.xml list.xml --check-page)"
assert_contains "forced check reads OPEN" "$out" "page: OPEN"
assert_eq "open: exactly one phone alert" "1" "$(notify_count)"
assert_eq "open: exactly one inbox message" "1" "$(inbox_count)"
assert_contains "phone alert carries the link" "$(cat "$CASE_DIR/logs/notify.log")" "AUR sign-up is open: https://aur.archlinux.org/register"
watch open-200.html 200 news.xml list.xml --check-page >/dev/null
assert_eq "still open: no second phone alert" "1" "$(notify_count)"
assert_eq "still open: no second inbox message" "1" "$(inbox_count)"
watch closed-503.html 503 news.xml list.xml --check-page >/dev/null
watch open-200.html 200 news.xml list.xml --check-page >/dev/null
assert_eq "closed then open again: alerts again" "2" "$(notify_count)"

echo "-- open on the very first run alerts too --"
new_case first-open
watch open-200.html 200 news.xml list.xml >/dev/null
assert_eq "first-run open: one phone alert" "1" "$(notify_count)"

echo "-- a failed phone alert is retried, the inbox is not repeated --"
new_case retry
watch closed-503.html 503 news.xml list.xml >/dev/null
FAIL_NOTIFY=1 watch open-200.html 200 news.xml list.xml --check-page >/dev/null
assert_eq "retry: phone alert failed" "0" "$(notify_count)"
assert_eq "retry: inbox sent" "1" "$(inbox_count)"
watch open-200.html 200 news.xml list.xml >/dev/null
assert_eq "retry: phone alert sent on the next run" "1" "$(notify_count)"
assert_eq "retry: inbox not repeated" "1" "$(inbox_count)"

echo "-- leads: only staff posts about registration --"
new_case leads
watch closed-503.html 503 news.xml list.xml >/dev/null
out="$(watch closed-503.html 503 news.xml list-user-post.xml)"
assert_contains "a user's registration post is no lead" "$out" "leads: 0"
out="$(watch closed-503.html 503 news.xml list-staff-lead.xml)"
assert_contains "a staff post is a lead" "$out" "leads: 1"
assert_contains "a lead checks the page now" "$out" "page: CLOSED"
assert_eq "lead + closed: no phone alert" "0" "$(notify_count)"
assert_eq "lead + closed: one inbox FYI" "1" "$(inbox_count)"
assert_contains "FYI links the post" "$(cat "$CASE_DIR/logs/inbox.log")" "message/STAFFPOST1/"
out="$(watch open-200.html 200 news-lead.xml list-staff-lead.xml)"
assert_contains "an Arch news post is a lead" "$out" "leads: 1"
assert_eq "lead + open: one phone alert" "1" "$(notify_count)"
out="$(watch open-200.html 200 news-lead.xml list-staff-lead.xml)"
assert_contains "a seen item is no lead again" "$out" "leads: 0"

echo "-- the first read of a feed is a baseline, not a lead --"
new_case baseline
out="$(watch closed-503.html 503 news-lead.xml list-staff-lead.xml)"
assert_contains "baseline: no leads" "$out" "leads: 0"
assert_eq "baseline: no inbox message" "0" "$(inbox_count)"

echo "-- unreadable page: one alert after three in a row --"
new_case unknown
for _ in 1 2; do watch anubis-challenge.html 200 news.xml list.xml --check-page >/dev/null; done
assert_eq "two unreadable: no alert yet" "0" "$(notify_count)"
watch anubis-challenge.html 200 news.xml list.xml --check-page >/dev/null
assert_eq "three unreadable: one alert" "1" "$(notify_count)"
assert_contains "the alert says it can't read the page" "$(cat "$CASE_DIR/logs/notify.log")" "AUR watch can't read the page"
watch anubis-challenge.html 200 news.xml list.xml --check-page >/dev/null
assert_eq "four unreadable: still one alert" "1" "$(notify_count)"
watch closed-503.html 503 news.xml list.xml --check-page >/dev/null
for _ in 1 2 3; do watch no-form-200.html 200 news.xml list.xml --check-page >/dev/null; done
assert_eq "recovery re-arms the alert" "2" "$(notify_count)"

echo "-- unreadable feeds: one alert after three runs --"
new_case feeds
for _ in 1 2 3 4; do watch closed-503.html 503 missing.xml list.xml >/dev/null; done
assert_eq "feeds unreadable: one alert" "1" "$(notify_count)"
assert_contains "the alert says it can't read the feeds" "$(cat "$CASE_DIR/logs/notify.log")" "AUR watch can't read the feeds"

echo "-- install.sh --aur-watch --"
home="$TMPDIR_TEST/install-home"
out="$(env -u XDG_CONFIG_HOME HOME="$home" SECRETS_SKIP_SYSTEMCTL=1 bash "$INSTALLER" --aur-watch)"
units="$home/.config/systemd/user"
assert_file "watcher installed" "$home/.local/bin/aur-registration-watch"
assert_file "service installed" "$units/aur-registration-watch.service"
assert_file "timer installed" "$units/aur-registration-watch.timer"
assert_contains "service runs the installed watcher" "$(cat "$units/aur-registration-watch.service")" "ExecStart=$home/.local/bin/aur-registration-watch"
assert_contains "timer fires four times an hour" "$(cat "$units/aur-registration-watch.timer")" "OnCalendar=*:0/15"
assert_contains "timer catches up after downtime" "$(cat "$units/aur-registration-watch.timer")" "Persistent=true"
if [[ ! -e "$home/.local/lib/secrets" ]]; then
    echo "  PASS: --aur-watch installs only the watcher"
    ((PASS_COUNT++)) || true
else
    echo "  FAIL: --aur-watch also installed the library"
    ((FAIL_COUNT++)) || true
fi
if PREFIX=/usr DESTDIR="$TMPDIR_TEST/stage" bash "$INSTALLER" --aur-watch >/dev/null 2>&1; then
    echo "  FAIL: --aur-watch accepted a packaged layout"
    ((FAIL_COUNT++)) || true
else
    echo "  PASS: --aur-watch refuses PREFIX/DESTDIR"
    ((PASS_COUNT++)) || true
fi
home="$TMPDIR_TEST/xdg-home"
xdg="$TMPDIR_TEST/xdg-config"
HOME="$home" XDG_CONFIG_HOME="$xdg" SECRETS_SKIP_SYSTEMCTL=1 bash "$INSTALLER" --aur-watch >/dev/null
assert_file "XDG_CONFIG_HOME: service under it" "$xdg/systemd/user/aur-registration-watch.service"
assert_file "XDG_CONFIG_HOME: timer under it" "$xdg/systemd/user/aur-registration-watch.timer"
if [[ ! -e "$home/.config" ]]; then
    echo "  PASS: XDG_CONFIG_HOME: nothing under ~/.config"
    ((PASS_COUNT++)) || true
else
    echo "  FAIL: XDG_CONFIG_HOME: installer also wrote $home/.config"
    ((FAIL_COUNT++)) || true
fi

echo "-- the live watcher is untouched --"
assert_eq "live service, timer and watcher unchanged" "$REAL_BEFORE" "$(fingerprint "${REAL_FILES[@]}")"

# ─────────────────────────────────────────────────────────────────────────────
#   Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ $FAIL_COUNT -eq 0 ]]

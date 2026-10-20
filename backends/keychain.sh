#!/bin/bash
# keychain.sh - macOS Keychain backend for secrets library
#
# Provides secret storage using the macOS Security framework (security CLI).
# Secrets are stored as generic passwords with:
#   service = $SECRETS_SERVICE (namespace/application identifier)
#   account = key name (unique within service)
#   label   = key name (for human readability in Keychain Access)
#
# Requires: macOS with 'security' command available
# Variable: SECRETS_SERVICE must be set before sourcing
# Optional: SECRETS_KEYCHAIN - keychain file to check/unlock
#           (default: ~/Library/Keychains/login.keychain-db)
#
# `security` exit codes callers need to tell apart (SecBase.h OSStatus → CLI):
#   36 = errSecInteractionNotAllowed  keychain locked and no UI to prompt
#                                     (e.g. tmux server outside the GUI session)
#   44 = errSecItemNotFound           no such entry — a genuine "not found"
#   51 = errSecUserCanceled           user dismissed the unlock dialog
# Every read below records the raw exit code in __SECRETS_LAST_RC and returns
# it unchanged so that secrets.sh can distinguish "locked" from "missing".

__SECRETS_LAST_RC=0

# ─────────────────────────────────────────────────────────────────────────────
#   Keychain State
# ─────────────────────────────────────────────────────────────────────────────

__secret_keychain_path() {
    echo "${SECRETS_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
}

__secret_keychain_locked() {
    # Returns 0 when the keychain is locked (or interaction was denied),
    # 1 when unlocked or when the state cannot be determined — an unknown
    # error must never be reported as "locked".
    local rc=0
    security show-keychain-info "$(__secret_keychain_path)" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        36|51) return 0 ;;
        *)     return 1 ;;
    esac
}

__secret_unlock_keychain() {
    # Interactive unlock on the controlling TTY. `security` prompts for the
    # password itself: it is never passed as an argument (-p) and never read
    # into a shell variable.
    if ! __secret_keychain_locked; then
        echo "[secrets] keychain already unlocked" >&2
        return 0
    fi

    if ! { : </dev/tty; } 2>/dev/null; then
        echo "[secrets] keychain is locked and there is no TTY to prompt on — run: secret_unlock" >&2
        return 2
    fi

    echo "[secrets] login keychain is locked — enter your macOS login password to unlock it (Ctrl-C or empty password to skip)" >&2
    local rc=0
    # Ctrl-C at the prompt reaches the whole foreground process group. Without
    # a handler zsh treats it as an interrupt of the caller too and silently
    # abandons the rest of the rc file being sourced (exports never run). With
    # a handler only `security` dies (rc 130) and we report and continue.
    # Reset afterwards: `trap -p` is not portable to zsh, so a pre-existing INT
    # trap set before sourcing this library is not preserved.
    trap ':' INT
    security unlock-keychain "$(__secret_keychain_path)" </dev/tty >/dev/tty 2>&1 || rc=$?
    trap - INT
    if [[ $rc -eq 0 ]]; then
        echo "[secrets] keychain unlocked" >&2
        return 0
    fi
    echo "[secrets] keychain unlock skipped/failed (security exit $rc)" >&2
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
#   Core Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_keychain_try() {
    # One find-generic-password attempt with the given selectors. stderr is
    # suppressed (noisy), but the exit code is recorded and returned as-is.
    security find-generic-password "$@" -w 2>/dev/null
    __SECRETS_LAST_RC=$?
    return $__SECRETS_LAST_RC
}

__secret_get_keychain() {
    local key="$1"
    __secret_get_keychain_try -a "$key" -s "$SECRETS_SERVICE"
}

# `security -i` reads each command line into a static 4096-byte buffer
# (SecurityTool readline.c, MAX_LINE_LEN). A longer line is cut and the rest
# runs as a second command; a 4095-byte line leaves its newline behind as an
# empty command whose status 0 masks the real one. So the line, without its
# newline, must stay at or below 4094 bytes.
__SECRETS_KEYCHAIN_MAX_LINE=4094

__secret_keychain_quote() {
    # Quote one argument for `security -i`'s split_line parser: inside "..."
    # a backslash escapes any character, so only \ and " need escaping.
    local arg="$1"
    arg="${arg//\\/\\\\}"
    arg="${arg//\"/\\\"}"
    printf '"%s"' "$arg"
}

__secret_set_keychain() {
    local key="$1"
    local value="$2"
    # The value goes to `security -i` on stdin, never in argv, where `ps`
    # would show it for as long as the call runs. -i ends a command at a
    # newline, so a value (or key) containing one cannot be stored this way.
    if [[ "$key$value$SECRETS_SERVICE" == *$'\n'* ]]; then
        echo "[secrets] cannot store '${key%%$'\n'*}': the keychain backend does not support newlines in a key or value" >&2
        return 2
    fi
    # -U updates if exists, otherwise creates
    local line
    line="add-generic-password -U -a $(__secret_keychain_quote "$key") -s $(__secret_keychain_quote "$SECRETS_SERVICE") -l $(__secret_keychain_quote "$key") -w $(__secret_keychain_quote "$value")"
    local line_bytes
    # Bytes, not characters (${#line} counts characters in a UTF-8 locale);
    # $(( )) also drops the padding BSD wc puts before the count.
    line_bytes=$(( $(printf '%s' "$line" | wc -c) ))
    if (( line_bytes > __SECRETS_KEYCHAIN_MAX_LINE )); then
        echo "[secrets] cannot store '$key': value too long for the keychain backend (command line is $line_bytes bytes, max $__SECRETS_KEYCHAIN_MAX_LINE)" >&2
        return 2
    fi
    # -q: no "returned N" chatter; the exit status is the command's own.
    # stdout suppressed: -U prints deleted entry details on update
    printf '%s\n' "$line" | security -q -i &>/dev/null
}

__secret_delete_keychain() {
    local key="$1"
    # stdout suppressed: delete prints entry details
    security delete-generic-password -a "$key" -s "$SECRETS_SERVICE" &>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
#   List Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_list_keychain() {
    # List keys within the current SECRETS_SERVICE namespace
    security dump-keychain 2>/dev/null | \
        awk -v svc="$SECRETS_SERVICE" '
            /^keychain:/ { acct = "" }
            /"acct"<blob>=/ {
                gsub(/.*="/, ""); gsub(/".*/, "")
                acct = $0
            }
            /"svce"<blob>=/ && $0 ~ "=\"" svc "\"" {
                if (acct != "") print acct
            }
        '
}

__secret_list_keychain_all() {
    # List ALL generic password entries in service:account format
    security dump-keychain 2>/dev/null | \
        awk '
            /^keychain:/ { svc = ""; acct = "" }
            /"acct"<blob>=/ {
                gsub(/.*="/, ""); gsub(/".*/, "")
                acct = $0
            }
            /"svce"<blob>=/ {
                gsub(/.*="/, ""); gsub(/".*/, "")
                svc = $0
                if (svc != "" && acct != "") print svc ":" acct
            }
        ' | sort -u
}

# ─────────────────────────────────────────────────────────────────────────────
#   Cross-Service Lookup
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_keychain_any() {
    # Search across all services for a secret
    # Supports: "service:account" format or plain key search
    # A locked keychain (36) or a cancelled prompt (51) stops the search:
    # every further attempt would fail identically (or prompt again).
    local key="$1"

    # Check for service:account format
    if [[ "$key" == *:* ]]; then
        local svc="${key%:*}"
        local acct="${key##*:}"
        __secret_get_keychain_try -s "$svc" -a "$acct" && return 0
        case "$__SECRETS_LAST_RC" in 36|51) return $__SECRETS_LAST_RC ;; esac
    fi

    # Try as account name
    __secret_get_keychain_try -a "$key" && return 0
    case "$__SECRETS_LAST_RC" in 36|51) return $__SECRETS_LAST_RC ;; esac
    # Try as service name
    __secret_get_keychain_try -s "$key" && return 0
    case "$__SECRETS_LAST_RC" in 36|51) return $__SECRETS_LAST_RC ;; esac
    # Try as label
    __secret_get_keychain_try -l "$key" && return 0
    return $__SECRETS_LAST_RC
}

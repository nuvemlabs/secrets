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

# ─────────────────────────────────────────────────────────────────────────────
#   Core Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_keychain() {
    local key="$1"
    security find-generic-password -a "$key" -s "$SECRETS_SERVICE" -w 2>/dev/null
}

__secret_set_keychain() {
    local key="$1"
    local value="$2"
    # -U updates if exists, otherwise creates
    # stdout suppressed: -U prints deleted entry details on update
    security add-generic-password -U -a "$key" -s "$SECRETS_SERVICE" -l "$key" -w "$value" &>/dev/null
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
    local key="$1"

    # Check for service:account format
    if [[ "$key" == *:* ]]; then
        local svc="${key%:*}"
        local acct="${key##*:}"
        security find-generic-password -s "$svc" -a "$acct" -w 2>/dev/null && return 0
    fi

    # Try as account name
    security find-generic-password -a "$key" -w 2>/dev/null && return 0
    # Try as service name
    security find-generic-password -s "$key" -w 2>/dev/null && return 0
    # Try as label
    security find-generic-password -l "$key" -w 2>/dev/null && return 0
    return 1
}

#!/bin/bash
# libsecret.sh - Linux libsecret backend for secrets library
#
# Provides secret storage using the GNOME libsecret framework (secret-tool CLI).
# Secrets are stored with attributes:
#   service = $SECRETS_SERVICE (namespace/application identifier)
#   key     = key name (unique within service)
#   label   = key name (for human readability)
#
# Requires: secret-tool (part of libsecret-tools package)
# Variable: SECRETS_SERVICE must be set before sourcing

# ─────────────────────────────────────────────────────────────────────────────
#   Core Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_libsecret() {
    local key="$1"
    secret-tool lookup service "$SECRETS_SERVICE" key "$key" 2>/dev/null
}

__secret_set_libsecret() {
    local key="$1"
    local value="$2"
    echo -n "$value" | secret-tool store --label="$key" service "$SECRETS_SERVICE" key "$key" 2>/dev/null
}

__secret_delete_libsecret() {
    local key="$1"
    secret-tool clear service "$SECRETS_SERVICE" key "$key" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
#   List Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_list_libsecret() {
    # List keys within the current SECRETS_SERVICE namespace.
    # secret-tool prints the attribute.* lines on stderr and the label/secret
    # block on stdout, so read stderr only: secret values never enter the pipe.
    secret-tool search --all service "$SECRETS_SERVICE" 2>&1 >/dev/null | \
        awk -F' = ' '/^attribute\.key = / { print $2 }'
}

__secret_list_libsecret_all() {
    # secret-tool cannot enumerate across services: every search needs at
    # least one attribute=value pair and there is no wildcard. Say so instead
    # of printing an empty list that reads as "no secrets".
    echo "secret_list -a: not supported on the libsecret backend (secret-tool needs a service);" \
         "list one service with: SECRETS_SERVICE=<name> secret_list" >&2
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
#   Cross-Service Lookup
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_libsecret_any() {
    # Accepts "service:key" (as printed by __secret_list_libsecret_all) or a
    # bare key, which matches that key in any service.
    local key="$1"
    if [[ "$key" == *:* ]]; then
        secret-tool lookup service "${key%:*}" key "${key##*:}" 2>/dev/null && return 0
    fi
    secret-tool lookup key "$key" 2>/dev/null
}

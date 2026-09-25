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

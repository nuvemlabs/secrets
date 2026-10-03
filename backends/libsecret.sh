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
    # List entries across ALL services as service:key, the format that
    # __secret_get_libsecret_any accepts. secret-tool cannot do this (every
    # search needs an attribute=value pair), so ask the Secret Service over
    # D-Bus: SearchItems with no attributes returns every item, locked or not,
    # and only each item's attributes are read, never its secret. gdbus ships
    # with glib, which libsecret itself depends on. Items from other apps
    # without a service/key pair are skipped.
    if ! command -v gdbus &>/dev/null; then
        echo "secret_list -a: needs gdbus (glib) on the libsecret backend;" \
             "list one service with: SECRETS_SERVICE=<name> secret_list" >&2
        return 1
    fi
    local dest=org.freedesktop.secrets items item attrs svc key
    items=$(gdbus call --session --dest "$dest" --object-path /org/freedesktop/secrets \
        --method org.freedesktop.Secret.Service.SearchItems '@a{ss} {}' 2>/dev/null) || {
        echo "secret_list -a: Secret Service not reachable on the session bus" >&2
        return 1
    }
    while IFS= read -r item; do
        attrs=$(gdbus call --session --dest "$dest" --object-path "$item" \
            --method org.freedesktop.DBus.Properties.Get \
            org.freedesktop.Secret.Item Attributes 2>/dev/null) || continue
        svc=$(sed -n "s/.*'service': '\([^']*\)'.*/\1/p" <<<"$attrs")
        key=$(sed -n "s/.*'key': '\([^']*\)'.*/\1/p" <<<"$attrs")
        if [[ -n "$svc" && -n "$key" ]]; then
            echo "$svc:$key"
        fi
    done < <(grep -o "'/org/freedesktop/secrets/[^']*'" <<<"$items" | tr -d "'") | sort -u
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

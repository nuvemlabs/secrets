#!/bin/bash
# file.sh - File-based fallback backend for secrets library
#
# Provides read-only secret access from a KEY=VALUE flat file.
# Supports comments (lines starting with #) and blank lines.
#
# This is a fallback backend for systems without a native secret store.
# It does NOT support set or delete operations.
#
# File location (in priority order):
#   1. $SECRETS_FILE_PATH (configurable override)
#   2. $HOME/.accessTokens (default)

# ─────────────────────────────────────────────────────────────────────────────
#   File Location
# ─────────────────────────────────────────────────────────────────────────────

__secrets_file() {
    # Return the path to the secrets file, if it exists
    if [[ -n "${SECRETS_FILE_PATH:-}" && -f "$SECRETS_FILE_PATH" ]]; then
        echo "$SECRETS_FILE_PATH"
    elif [[ -f "$HOME/.accessTokens" ]]; then
        echo "$HOME/.accessTokens"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   Core Operations (read-only)
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_file() {
    local key="$1"
    local file
    file=$(__secrets_file)
    [[ -z "$file" ]] && return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ''|\#*) continue ;;
            "$key="*)
                echo "${line#*=}"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
#   List Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_list_file() {
    local file
    file=$(__secrets_file)
    [[ -z "$file" ]] && return

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ''|\#*) continue ;;
            *=*)
                echo "${line%%=*}"
                ;;
        esac
    done < "$file"
}

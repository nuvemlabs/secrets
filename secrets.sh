#!/bin/bash
# secrets.sh - Cross-platform secrets management library
#
# Supports macOS Keychain, Windows Credential Manager, Linux libsecret,
# and file-based fallback. Auto-detects the best available backend.
#
# Usage:
#   source /path/to/secrets.sh
#
#   secret KEY              - Get a secret from the current service
#   secret -a KEY           - Get a secret from any service (--all)
#   secret_set KEY VALUE    - Store a secret
#   secret_list             - List secrets in current service
#   secret_list -a          - List ALL secrets across services (--all)
#   secret_delete KEY       - Remove a secret
#   secret_fz               - Interactive fzf selection
#   secret_fz -a            - Interactive fzf selection (all services)
#   secret_fz -p            - With preview pane showing values
#   secret_fz -c            - Select and copy to clipboard
#
# Aliases: sl (secret_list), sfz (secret_fz)
# Use -h or --help on any command for usage info
#
# Configuration:
#   SECRETS_SERVICE  - Namespace for secrets (default: "secrets")
#   SECRETS_FILE_PATH - Override file backend path (default: ~/.accessTokens)

# ─────────────────────────────────────────────────────────────────────────────
#   Initialization
# ─────────────────────────────────────────────────────────────────────────────

# Support both bash (BASH_SOURCE) and zsh (%x prompt expansion)
if [ -n "$ZSH_VERSION" ]; then
    SECRETS_DIR="${${(%):-%x}:A:h}"
elif [ -n "$BASH_SOURCE" ]; then
    SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Fallback to a known location
    SECRETS_DIR="${HOME}/.local/lib/secrets"
fi

# Default service namespace (callers can set this before sourcing)
: "${SECRETS_SERVICE:=secrets}"

# ─────────────────────────────────────────────────────────────────────────────
#   Backend Detection
# ─────────────────────────────────────────────────────────────────────────────

__secrets_backend() {
    if [[ "$OSTYPE" == darwin* ]] && command -v security &>/dev/null; then
        echo "keychain"
    elif command -v powershell.exe &>/dev/null || command -v pwsh &>/dev/null; then
        echo "credmanager"
    elif command -v secret-tool &>/dev/null; then
        echo "libsecret"
    else
        echo "file"
    fi
}

# Detect once and cache the result
__SECRETS_BACKEND="$(__secrets_backend)"

# ─────────────────────────────────────────────────────────────────────────────
#   Backend Sourcing
# ─────────────────────────────────────────────────────────────────────────────

case "$__SECRETS_BACKEND" in
    keychain)    source "$SECRETS_DIR/backends/keychain.sh" ;;
    credmanager) source "$SECRETS_DIR/backends/credmanager.sh" ;;
    libsecret)   source "$SECRETS_DIR/backends/libsecret.sh" ;;
    file)        source "$SECRETS_DIR/backends/file.sh" ;;
esac

# File backend is always sourced for fallback lookups
if [[ "$__SECRETS_BACKEND" != "file" ]]; then
    source "$SECRETS_DIR/backends/file.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
#   Public API
# ─────────────────────────────────────────────────────────────────────────────

secret() {
    local all_services=false
    local key=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<EOF
Usage: secret [-a|--all] KEY

Get a secret value from the secret store.

Options:
  -a, --all    Search across ALL services, not just $SECRETS_SERVICE
  -h, --help   Show this help message

Examples:
  secret OPENAI_API_KEY                    # From $SECRETS_SERVICE service
  secret -a "service:account"              # From any service (use format from sl -a)
EOF
                return 0 ;;
            -a|--all) all_services=true; shift ;;
            -*) echo "Unknown option: $1. Use -h for help." >&2; return 1 ;;
            *) key="$1"; shift ;;
        esac
    done

    [[ -z "$key" ]] && { echo "Usage: secret [-a|--all] KEY (use -h for help)" >&2; return 1; }

    local backend="$__SECRETS_BACKEND"
    local value=""

    if [[ "$all_services" == true ]]; then
        # Search across all services
        case "$backend" in
            keychain)
                value=$(__secret_get_keychain_any "$key")
                ;;
            credmanager)
                # credmanager has no cross-service search; try current service
                value=$(__secret_get_credmanager "$key")
                ;;
            libsecret)
                # Search without service filter
                value=$(secret-tool lookup key "$key" 2>/dev/null)
                ;;
        esac
    else
        # Search only in current service
        case "$backend" in
            keychain)
                value=$(__secret_get_keychain "$key")
                ;;
            credmanager)
                value=$(__secret_get_credmanager "$key")
                ;;
            libsecret)
                value=$(__secret_get_libsecret "$key")
                ;;
        esac
    fi

    # Fallback to file if native store returned empty
    if [[ -z "$value" ]]; then
        value=$(__secret_get_file "$key")
    fi

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "Secret '$key' not found" >&2
        return 1
    fi
}

secret_set() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<EOF
Usage: secret_set KEY VALUE

Store a secret in the native secret store ($SECRETS_SERVICE service).

Examples:
  secret_set OPENAI_API_KEY "sk-..."
  secret_set MY_TOKEN "abc123"
EOF
        return 0
    fi

    local key="${1:-}"
    local value="${2:-}"
    [[ -z "$key" || -z "$value" ]] && { echo "Usage: secret_set KEY VALUE (use -h for help)" >&2; return 1; }

    local backend="$__SECRETS_BACKEND"

    case "$backend" in
        keychain)
            __secret_set_keychain "$key" "$value"
            ;;
        credmanager)
            __secret_set_credmanager "$key" "$value"
            ;;
        libsecret)
            __secret_set_libsecret "$key" "$value"
            ;;
        file)
            echo "No native secret store available. Cannot store secrets with file backend." >&2
            return 1
            ;;
    esac
}

secret_delete() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<EOF
Usage: secret_delete KEY

Remove a secret from the native secret store ($SECRETS_SERVICE service).

Examples:
  secret_delete OLD_API_KEY
EOF
        return 0
    fi

    local key="${1:-}"
    [[ -z "$key" ]] && { echo "Usage: secret_delete KEY (use -h for help)" >&2; return 1; }

    local backend="$__SECRETS_BACKEND"

    case "$backend" in
        keychain)
            __secret_delete_keychain "$key"
            ;;
        credmanager)
            __secret_delete_credmanager "$key"
            ;;
        libsecret)
            __secret_delete_libsecret "$key"
            ;;
        file)
            echo "No native secret store available." >&2
            return 1
            ;;
    esac
}

secret_list() {
    local all_services=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<EOF
Usage: secret_list [-a|--all]

List secrets from the secret store.

Options:
  -a, --all    List ALL entries across services (format: service:account)
  -h, --help   Show this help message

Alias: sl

Examples:
  secret_list              # List $SECRETS_SERVICE secrets only
  sl -a                    # List all entries
  sl -a | grep github      # Search all entries
EOF
                return 0 ;;
            -a|--all) all_services=true; shift ;;
            -*) echo "Unknown option: $1. Use -h for help." >&2; return 1 ;;
            *) shift ;;
        esac
    done

    local backend="$__SECRETS_BACKEND"

    if [[ "$all_services" == true ]]; then
        case "$backend" in
            keychain)
                __secret_list_keychain_all
                ;;
            credmanager)
                __secret_list_credmanager_all
                ;;
            libsecret)
                # List all libsecret entries
                secret-tool search --all 2>/dev/null | \
                    awk -F' = ' '/^attribute\./ { print $1 "=" $2 }' | sort -u
                ;;
            file)
                __secret_list_file
                ;;
        esac
    else
        case "$backend" in
            keychain)
                __secret_list_keychain
                ;;
            credmanager)
                __secret_list_credmanager
                ;;
            libsecret)
                __secret_list_libsecret
                ;;
            file)
                __secret_list_file
                ;;
        esac
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   Interactive Selection
# ─────────────────────────────────────────────────────────────────────────────

secret_fz() {
    local all_flag=""
    local copy=false
    local preview=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'EOF'
Usage: secret_fz [-a|--all] [-p|--preview] [-c|--copy]

Interactive secret selection using fzf.

Options:
  -a, --all      Browse ALL entries, not just current service
  -p, --preview  Show secret value in preview pane
  -c, --copy     Copy selected secret to clipboard (instead of printing)
  -h, --help     Show this help message

Alias: sfz

Examples:
  sfz                # Browse current service secrets
  sfz -a -p          # Browse all with preview
  sfz -c             # Select and copy to clipboard
  sfz -a -p -c       # All options combined
EOF
                return 0 ;;
            -a|--all) all_flag="-a"; shift ;;
            -c|--copy) copy=true; shift ;;
            -p|--preview) preview=true; shift ;;
            -*) echo "Unknown option: $1. Use -h for help." >&2; return 1 ;;
            *) shift ;;
        esac
    done

    if ! command -v fzf &>/dev/null; then
        echo "fzf is required for secret_fz" >&2
        return 1
    fi

    local fzf_opts=(--header="Select secret (Enter=print, Ctrl-C=cancel)")
    if [[ "$preview" == true ]]; then
        fzf_opts+=(
            --preview="source '$SECRETS_DIR/secrets.sh' 2>/dev/null; secret $all_flag '{}' 2>/dev/null || echo '[Access denied or not found]'"
            --preview-window=down:3:wrap
        )
    fi

    local selected
    selected=$(secret_list $all_flag | fzf "${fzf_opts[@]}")

    [[ -z "$selected" ]] && return 0

    local value
    value=$(secret $all_flag "$selected" 2>/dev/null)

    if [[ -n "$value" ]]; then
        if [[ "$copy" == true ]] && command -v pbcopy &>/dev/null; then
            echo -n "$value" | pbcopy
            echo "Copied to clipboard: $selected"
        elif [[ "$copy" == true ]] && command -v xclip &>/dev/null; then
            echo -n "$value" | xclip -selection clipboard
            echo "Copied to clipboard: $selected"
        elif [[ "$copy" == true ]] && command -v clip.exe &>/dev/null; then
            echo -n "$value" | clip.exe
            echo "Copied to clipboard: $selected"
        else
            echo "$value"
        fi
    else
        echo "Could not retrieve secret" >&2
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   Aliases
# ─────────────────────────────────────────────────────────────────────────────

sl() { secret_list "$@"; }
sfz() { secret_fz "$@"; }

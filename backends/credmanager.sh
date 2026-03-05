#!/bin/bash
# credmanager.sh - Windows Credential Manager backend for secrets library
#
# Provides secret storage using Windows Credential Manager via PowerShell.
# Requires the CredentialManager PowerShell module (Install-Module CredentialManager).
# Secrets are stored as Generic credentials with target:
#   ${SECRETS_SERVICE}:${key}
#
# Works in Git Bash, WSL, and MSYS2 environments.
#
# Requires: PowerShell (powershell.exe or pwsh) with CredentialManager module
# Variable: SECRETS_SERVICE must be set before sourcing
# Variable: SECRETS_POWERSHELL can override the PowerShell binary (default: powershell.exe)

# Resolve the PowerShell binary to use
__credmanager_powershell() {
    echo "${SECRETS_POWERSHELL:-powershell.exe}"
}

# ─────────────────────────────────────────────────────────────────────────────
#   Core Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_credmanager() {
    local key="$1"
    local ps
    ps=$(__credmanager_powershell)
    "$ps" -NoProfile -NonInteractive -Command "
        \$cred = Get-StoredCredential -Target '${SECRETS_SERVICE}:${key}'
        if (\$cred) {
            \$cred.GetNetworkCredential().Password
        }
    " 2>/dev/null | tr -d '\r'
}

__secret_set_credmanager() {
    local key="$1"
    local value="$2"
    local ps
    ps=$(__credmanager_powershell)
    "$ps" -NoProfile -NonInteractive -Command "
        New-StoredCredential -Target '${SECRETS_SERVICE}:${key}' \
            -UserName '${key}' \
            -Password '${value}' \
            -Type Generic \
            -Persist LocalMachine | Out-Null
    " 2>/dev/null | tr -d '\r'
}

__secret_delete_credmanager() {
    local key="$1"
    local ps
    ps=$(__credmanager_powershell)
    "$ps" -NoProfile -NonInteractive -Command "
        Remove-StoredCredential -Target '${SECRETS_SERVICE}:${key}'
    " 2>/dev/null | tr -d '\r'
}

# ─────────────────────────────────────────────────────────────────────────────
#   List Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_list_credmanager() {
    # List keys within the current SECRETS_SERVICE namespace
    local ps
    ps=$(__credmanager_powershell)
    "$ps" -NoProfile -NonInteractive -Command "
        Get-StoredCredential -Target '${SECRETS_SERVICE}:*' -AsCredentialObject |
            ForEach-Object {
                \$_.TargetName -replace '^${SECRETS_SERVICE}:', ''
            }
    " 2>/dev/null | tr -d '\r'
}

__secret_list_credmanager_all() {
    # List ALL stored credentials
    local ps
    ps=$(__credmanager_powershell)
    "$ps" -NoProfile -NonInteractive -Command "
        Get-StoredCredential -AsCredentialObject |
            ForEach-Object { \$_.TargetName }
    " 2>/dev/null | tr -d '\r'
}

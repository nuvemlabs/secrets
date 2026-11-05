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
# The PowerShell scripts below are constant text. Values reach PowerShell on
# stdin, never in its argv (where ps or Task Manager could see them); key and
# service names reach it in environment variables, never spliced into the
# script, so a quote in either cannot end a string and run as code.
#
# Requires: PowerShell (powershell.exe or pwsh) with CredentialManager module
# Variable: SECRETS_SERVICE must be set before sourcing
# Variable: SECRETS_POWERSHELL can override the PowerShell binary (default: powershell.exe)

# Environment variables that carry names (never values) into PowerShell.
__SECRETS_CM_ENV_SERVICE=SECRETS_CM_SERVICE
__SECRETS_CM_ENV_KEY=SECRETS_CM_KEY

# Resolve the PowerShell binary to use
__credmanager_powershell() {
    echo "${SECRETS_POWERSHELL:-powershell.exe}"
}

# Run a constant PowerShell script with the service and key in the
# environment. WSLENV lists them too: WSL only hands a Windows process the
# variables named there (Git Bash and MSYS2 pass the whole environment).
# Usage: __credmanager_run <key> <script>; stdin passes through.
__credmanager_run() {
    local key="$1"
    local script="$2"
    local ps
    ps=$(__credmanager_powershell)
    env "$__SECRETS_CM_ENV_SERVICE=$SECRETS_SERVICE" \
        "$__SECRETS_CM_ENV_KEY=$key" \
        "WSLENV=${WSLENV:+$WSLENV:}$__SECRETS_CM_ENV_SERVICE:$__SECRETS_CM_ENV_KEY" \
        "$ps" -NoProfile -NonInteractive -Command "$script"
}

# ─────────────────────────────────────────────────────────────────────────────
#   Core Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_get_credmanager() {
    local key="$1"
    __credmanager_run "$key" '
        $cred = Get-StoredCredential -Target ($env:SECRETS_CM_SERVICE + ":" + $env:SECRETS_CM_KEY)
        if ($cred) {
            $cred.GetNetworkCredential().Password
        }
    ' 2>/dev/null | tr -d '\r'
}

# The value goes in on stdin as UTF-8 bytes and is read back as such, so the
# console code page cannot mangle it. Errors stop the script, so PowerShell
# exits non-zero and that status is returned: a failed set never looks like
# success. Its stderr is left visible; it holds the script text, not the value.
__secret_set_credmanager() {
    local key="$1"
    local value="$2"
    printf '%s' "$value" | __credmanager_run "$key" '
        $ErrorActionPreference = "Stop"
        $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
        $value = $reader.ReadToEnd()
        New-StoredCredential -Target ($env:SECRETS_CM_SERVICE + ":" + $env:SECRETS_CM_KEY) `
            -UserName $env:SECRETS_CM_KEY `
            -Password $value `
            -Type Generic `
            -Persist LocalMachine | Out-Null
    ' >/dev/null
}

__secret_delete_credmanager() {
    local key="$1"
    __credmanager_run "$key" '
        Remove-StoredCredential -Target ($env:SECRETS_CM_SERVICE + ":" + $env:SECRETS_CM_KEY)
    ' 2>/dev/null | tr -d '\r'
}

# ─────────────────────────────────────────────────────────────────────────────
#   List Operations
# ─────────────────────────────────────────────────────────────────────────────

__secret_list_credmanager() {
    # List keys within the current SECRETS_SERVICE namespace. The prefix is
    # regex-escaped: a service name is text, not a pattern.
    __credmanager_run "" '
        $prefix = $env:SECRETS_CM_SERVICE + ":"
        Get-StoredCredential -Target ($prefix + "*") -AsCredentialObject |
            ForEach-Object {
                $_.TargetName -replace ("^" + [regex]::Escape($prefix)), ""
            }
    ' 2>/dev/null | tr -d '\r'
}

__secret_list_credmanager_all() {
    # List ALL stored credentials
    __credmanager_run "" '
        Get-StoredCredential -AsCredentialObject |
            ForEach-Object { $_.TargetName }
    ' 2>/dev/null | tr -d '\r'
}

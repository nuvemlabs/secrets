# secrets

Cross-platform OS-native secret storage CLI for bash.

![macOS](https://img.shields.io/badge/macOS-Keychain-000000?style=flat-square&logo=apple)
![Linux](https://img.shields.io/badge/Linux-libsecret-FCC624?style=flat-square&logo=linux&logoColor=black)
![Windows](https://img.shields.io/badge/Windows-Credential%20Manager-0078D4?style=flat-square&logo=windows)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Dependencies](https://img.shields.io/badge/dependencies-bash-blue?style=flat-square)

## Features

- **OS-native storage** - secrets stay in macOS Keychain, GNOME Keyring, or Windows Credential Manager
- **Auto-detection** - picks the best available backend at source time
- **Service namespacing** - isolate secrets per application via `SECRETS_SERVICE`
- **File fallback** - reads `~/.accessTokens` when no native store is available
- **Interactive selection** - `fzf`-powered picker with optional preview and clipboard copy
- **Cross-service search** - query all services with `-a` flag
- **Zero dependencies** - pure bash, no external packages beyond the OS-native tools

## Quick Start

```bash
# Install
git clone https://github.com/nuvemlabs/secrets.git
cd secrets && bash install.sh

# Add to your shell rc
echo 'source "$HOME/.local/lib/secrets/secrets.sh"' >> ~/.bashrc  # or ~/.zshrc

# Use it
secret_set MY_API_KEY "sk-abc123"
secret MY_API_KEY         # prints: sk-abc123
secret_list               # lists all keys in current service
secret_delete MY_API_KEY
```

## API Reference

| Command | Description |
|---------|-------------|
| `secret KEY` | Get a secret value |
| `secret -a KEY` | Get a secret from any service (cross-service search) |
| `secret_set KEY VALUE` | Store a secret in the native store |
| `secret_delete KEY` | Remove a secret |
| `secret_list` | List keys in the current service |
| `secret_list -a` | List all keys across all services |
| `secret_fz` | Interactive fzf selection |
| `secret_fz -a` | Interactive selection across all services |
| `secret_fz -p` | Interactive selection with value preview |
| `secret_fz -c` | Select and copy value to clipboard |

**Aliases:** `sl` for `secret_list`, `sfz` for `secret_fz`

All commands accept `-h` / `--help` for usage details.

## CLI Tools

Installed to `~/.local/bin` by `install.sh` (ensure it is on your PATH):

| Tool | Description |
|------|-------------|
| `secrets-doctor [KEY\|PREFIX ...]` | Diagnose secret propagation (store → exports file → shell env) without printing values. `--probe` flags empty/malformed stored values in-process; `--match REGEX` adds a shape check. Exit 0 = chain intact, 1 = broken. See `secrets-doctor --help`. |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRETS_SERVICE` | `secrets` | Namespace for stored secrets (acts as service/application identifier) |
| `SECRETS_FILE_PATH` | `~/.accessTokens` | Override the file fallback path |
| `SECRETS_POWERSHELL` | `powershell.exe` | Override the PowerShell binary (Windows only) |
| `SECRETS_INSTALL_DIR` | `~/.local/lib/secrets` | Override install location (used by `install.sh`) |
| `SECRETS_BIN_DIR` | `~/.local/bin` | Override CLI tools install location (used by `install.sh`) |
| `SECRETS_EXPORTS_FILE` | (unset) | Shell file with `export KEY="$(secret KEY)"` lines, read by `secrets-doctor` |

## Platform Details

| Platform | Backend | Underlying Tool | Storage Location |
|----------|---------|-----------------|------------------|
| macOS | `keychain` | `security` CLI | Login Keychain (`~/Library/Keychains/`) |
| Linux (GNOME/KDE) | `libsecret` | `secret-tool` | GNOME Keyring / KDE Wallet |
| Windows (Git Bash/WSL) | `credmanager` | PowerShell `CredentialManager` module | Windows Credential Manager |
| Any (fallback) | `file` | bash builtins | `~/.accessTokens` (read-only) |

## How It Works

```
source secrets.sh
       │
       ├── Detect OS & available tools
       │   ├── macOS + security     → keychain backend
       │   ├── powershell.exe/pwsh  → credmanager backend
       │   ├── secret-tool          → libsecret backend
       │   └── (none)               → file backend (read-only)
       │
       ├── Source selected backend
       └── Source file backend (always, for fallback reads)
```

Backend detection runs once at source time. The `secret` command queries the native backend first and falls back to the file backend if no value is found.

The file backend (`~/.accessTokens`) is always loaded alongside the native backend. This lets you keep legacy tokens in a flat file while storing new secrets in the OS-native store.

## License

MIT

# secrets

Cross-platform OS-native secret storage for bash and zsh.

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
- **Zero dependencies** - pure shell, nothing beyond the OS-native tools (Linux: `secret-tool`, from `libsecret` or `libsecret-tools`)

## Install

| Channel | Command | Library path to source |
|---------|---------|------------------------|
| Homebrew (macOS, Linux) | `brew install nuvemlabs/tap/secrets` | `$(brew --prefix)/lib/secrets/secrets.sh` |
| Arch (PKGBUILD) | `git clone https://github.com/nuvemlabs/secrets.git && cd secrets/packaging/aur && makepkg -si` | `/usr/lib/secrets/secrets.sh` |
| From source (any) | `git clone https://github.com/nuvemlabs/secrets.git && cd secrets && bash install.sh` | `~/.local/lib/secrets/secrets.sh` |

The Arch package is not on the AUR yet (new AUR accounts are paused); the
PKGBUILD above is the one that will be published as `nuvemlabs-secrets`.

Then load the library from your shell rc (`~/.bashrc` or `~/.zshrc`), using the path for your channel:

```bash
source "$HOME/.local/lib/secrets/secrets.sh"
```

`install.sh` installs per user by default. Packagers stage a system-wide layout with
`PREFIX=/usr DESTDIR="$pkgdir" bash install.sh` (library in `$PREFIX/lib/secrets`, CLI in `$PREFIX/bin`).

## Quick Start

```bash
secret set MY_API_KEY     # prompts for the value, input hidden, nothing in history
secret get MY_API_KEY     # prints it (short form: secret MY_API_KEY)
secret list               # lists all keys in current service
secret delete MY_API_KEY
```

## API Reference

Every command is a verb of `secret`; each verb is also a `secret_<verb>` function
(`secret_set`, `secret_list`, ...), and `secret KEY` is short for `secret get KEY`.
A key spelled like a verb (`list`, `rm`, ...) must be read with `secret get <name>`.

| Command | Description |
|---------|-------------|
| `secret get KEY` | Get a secret value (also `secret KEY`) |
| `secret get -a KEY` | Get a secret from any service (cross-service search) |
| `secret set KEY` | Store a secret, value read from stdin: a hidden prompt on a terminal, the first line of a pipe otherwise. Keeps it out of shell history |
| `secret set KEY VALUE` | Store a secret given on the command line |
| `secret delete KEY` | Remove a secret (alias `rm`) |
| `secret list` | List keys in the current service (alias `ls`) |
| `secret list -a` | List all keys across all services as `service:key` (libsecret: via the Secret Service D-Bus API, needs `gdbus`) |
| `secret fz` | Interactive fzf selection |
| `secret fz -a` | Interactive selection across all services |
| `secret fz -p` | Interactive selection with value preview |
| `secret fz -c` | Select and copy value to clipboard (`pbcopy`, `wl-copy` on Wayland, `xclip`, `clip.exe`) |
| `secret unlock` | Unlock a locked macOS login keychain from the terminal (keychain backend only; `security` prompts on the TTY). `secret` points here when it exits 2 with "keychain is locked" |
| `secret help` | List the commands |

**Aliases:** `sl` for `secret_list`, `sfz` for `secret_fz`

All commands accept `-h` / `--help` for usage details.

## CLI Tools

Installed next to the library: `~/.local/bin` from source, `/usr/bin` or the Homebrew prefix from a package.

| Tool | Description |
|------|-------------|
| `secrets-doctor [KEY\|PREFIX ...]` | Diagnose secret propagation (store → exports file → shell env) without printing values. `--probe` flags empty/malformed stored values in-process; `--match REGEX` adds a shape check. Exit 0 = chain intact, 1 = broken. See `secrets-doctor --help`. |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRETS_SERVICE` | `secrets` | Namespace for stored secrets (acts as service/application identifier) |
| `SECRETS_FILE_PATH` | `~/.accessTokens` | Override the file fallback path |
| `SECRETS_POWERSHELL` | `powershell.exe` | Override the PowerShell binary (Windows only) |
| `PREFIX` | (unset) | `install.sh`: install to `$PREFIX/lib/secrets` and `$PREFIX/bin` instead of `~/.local` |
| `DESTDIR` | (unset) | `install.sh`: staging root prepended to every path (package builds) |
| `SECRETS_INSTALL_DIR` | `~/.local/lib/secrets` | Override install location (used by `install.sh`) |
| `SECRETS_BIN_DIR` | `~/.local/bin` | Override CLI tools install location (used by `install.sh`) |
| `SECRETS_EXPORTS_FILE` | (unset) | Shell file with `export KEY="$(secret KEY)"` lines, read by `secrets-doctor` |
| `SECRETS_KEYCHAIN` | `~/Library/Keychains/login.keychain-db` | Keychain file checked/unlocked by `secret_unlock` (macOS only) |
| `SECRETS_AUTO_UNLOCK` | `0` | Set to `1` to prompt once on the TTY at source time when the keychain is locked (macOS only). Never prompts without a TTY |

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

## Development

```bash
for t in tests/test_*.sh; do bash "$t" || echo "FAILED: $t"; done
```

The keychain, libsecret and credmanager suites use a throwaway service namespace in the real
store and skip on platforms without it; the file, doctor and install suites are hermetic.
Packaging sources live in `packaging/` (AUR `PKGBUILD` + `.SRCINFO`, Homebrew formula).

## License

MIT

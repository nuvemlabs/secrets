# Secrets Library - Workflow State

## Status: COMPLETE (Tasks 1-6)

## Plan
1. Task 1: Initialize repository - create structure, LICENSE, .gitignore, commit [DONE]
2. Task 2: Extract macOS Keychain backend from dotfiles/lib/secrets.sh, write tests, run tests, commit [DONE]
3. Task 3: Extract Linux libsecret backend, write tests, commit [DONE]
4. Task 4: Extract file fallback backend, write tests, run tests, commit [DONE]
5. Task 5: Add Windows Credential Manager backend, write tests, commit [DONE]
6. Task 6: Write main secrets.sh public API with platform detection [DONE]

## Log
- Task 1: Created ~/repos/secrets/ with backends/ and tests/ dirs, git init, MIT LICENSE, .gitignore
- Task 2: Extracted keychain.sh from dotfiles reference, wrote test_keychain.sh (7 tests), fixed `set -e` + arithmetic, suppressed stdout on set/delete
- Task 3: Extracted libsecret.sh from dotfiles reference, wrote test_libsecret.sh (7 tests), skips correctly on non-Linux
- Task 4: Extracted file.sh with SECRETS_FILE_PATH override + $HOME/.accessTokens fallback, wrote test_file.sh (9 tests), all pass
- Task 5: Created credmanager.sh with PowerShell-based Windows Credential Manager functions, wrote test_credmanager.sh, fixed module detection to check output (not just exit code), skips correctly on non-Windows
- All tests verified passing: 16 pass across file + keychain, 2 suites skip gracefully (libsecret, credmanager)
- Task 6: Created secrets.sh (public API + backend detection + sourcing) and tests/test_api.sh (22 tests). Fixed `set -u` compat with `${1:-}` defaults. Fixed grep `--` for option-like strings. All 38 tests pass across 5 suites.

## Log — 2026-07-31 secrets-doctor CLI added (moved from dotfiles util-scripts)

- bin/secrets-doctor: propagation diagnostic (store → exports file → env), names-only default,
  opt-in --probe/--match in-process value validation. Genericized: SECRETS_EXPORTS_FILE config,
  lib resolved from checkout sibling or ~/.local/lib/secrets. Fixed known-key set to include
  derived export aliases (caught by new tests).
- install.sh: installs bin/ tools to ~/.local/bin (SECRETS_BIN_DIR override), chmod +x.
- tests/test_doctor.sh: 20 assertions incl. leak-proofing (no value on stdout/stderr/bash -x).
- README.md: CLI Tools section + new config vars.

## 2026-10-03 — Packaging for AUR + Homebrew (branch feat/packaging, on top of feat/doctor-store-only)

### Decisions
- D1 (2026-10-03) packaging: AUR package name `nuvemlabs-secrets`, not `secrets` — assumptions: "secrets" is too generic for a shared namespace (free today on AUR and homebrew-core) — undo: rename pkgname in PKGBUILD + README before the first AUR push
- D2 (2026-10-03) packaging: Homebrew via own tap `nuvemlabs/homebrew-tap`, formula `secrets` — assumptions: homebrew-core wants notability first; the tap namespaces the name — undo: drop packaging/homebrew
- D3 (2026-10-03) packaging: git tag sources (`#tag=v$pkgver`, brew `tag:`) instead of tarball + sha256 — assumptions: no hash exists until the tag is pushed — undo: switch to the release tarball and add its sha256
- D4 (2026-10-03) packaging: Linux package depends on `libsecret` (not optional) — assumptions: without secret-tool the library is read-only — undo: move it to optdepends
- D5 (2026-10-03) libsecret: `secret_list -a` enumerates over D-Bus with gdbus (SearchItems {} + per-item Attributes; never reads secrets), shipped as v1.1.1 — assumptions: user wants every feature working, not a clear error; gdbus comes with glib, a libsecret dependency — undo: revert fix/libsecret-list-all
- D6 (2026-10-03) packaging: Ubuntu PPA / Fedora COPR deferred — assumptions: user asked for brew + AUR first

### Log
- acae554 libsecret `sl -a` fails loudly (was always empty: secret-tool needs an attribute=value pair)
- f8ca0b7 doctor finds <prefix>/lib/secrets; --help no longer tied to fixed line numbers
- 7599715 install.sh PREFIX/DESTDIR + tests/test_install.sh (hermetic)
- e74ca4d packaging/aur (PKGBUILD, .SRCINFO), packaging/homebrew/secrets.rb, README install channels
- Verified: all 7 suites pass; makepkg build from local branch passes check() and ships the expected files; brew style clean except rules that only apply outside a tap; formula install() layout exercised via PREFIX
- dotfiles 39da759: config/shell/secrets.sh + installers/secrets.sh accept a packaged install

- D7 (2026-10-03) backend: `pwsh` selects credmanager only on Windows (msys/cygwin); `powershell.exe` still does (Git Bash, WSL) — assumptions: found by CI, ubuntu runners ship pwsh; Linux/macOS users with PowerShell Core would lose their native store — undo: revert the __secrets_backend hunk
- D8 (2026-10-03) ci: Linux job runs the libsecret suites against a throwaway gnome-keyring on a private dbus-run-session — assumptions: otherwise the Linux backend is never exercised in CI — undo: drop the Linux keyring steps

### Blocked on the user (outward-facing)
1. Merge feat/doctor-store-only + feat/packaging into main, push, tag + push v1.1.0
2. Create GitHub repo nuvemlabs/homebrew-tap, add Formula/secrets.rb, then `brew install nuvemlabs/tap/secrets && brew test secrets`
3. AUR: account + SSH key, `git clone ssh://aur@aur.archlinux.org/nuvemlabs-secrets.git`, copy PKGBUILD + .SRCINFO, push

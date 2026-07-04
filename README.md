# kittymgr

[![CI](https://github.com/joaaosc/garfield/actions/workflows/ci.yml/badge.svg)](https://github.com/joaaosc/garfield/actions/workflows/ci.yml)

A non-invasive configuration manager for the [kitty](https://sw.kovidgoyal.net/kitty/)
terminal. kittymgr never rewrites a user's `kitty.conf`; it attaches a single,
clearly fenced `include` block and keeps all managed state in a dedicated
`kittymgr/` subdirectory. Every change is backed up, idempotent, and reversible.

## Status

- Managed layer: `init`, `uninstall`.
- Profiles: `list`, `create`, `delete`, `switch`, `current` (also under the `profile` verb).
- Plugins (per-profile config snippets): `plugin list/enable/disable`.
- Backups & preview: `backup create/list/restore`, plus a global `--dry-run` flag.
- Atomic apply with rollback: `apply` (snapshot → write → validate → reload/rollback).
- Modular blocks: `theme`, `key`, `snippet`.
- Kittens (isolated scripts, never auto-run): `kitten list/install/remove`.
- Remote sources: install themes/plugins/kittens from git/URL; `theme install <name>` pulls from the built-in catalog.
- Declarative config: `kittymgr.toml` manifest (schema v2 — active selection, per-profile plugins, `keys`/`snippets` slugs, `[[sources]]`, and `[[themes]]`/`[[plugins]]`/`[[kittens]]`), `manifest init/show`, `source add/list/remove`.
- Reconcile & pin: `sync` (disk ↔ manifest; installs declared artifacts; snapshot + rollback), `update` / `update --check`, `kittymgr/kittymgr.lock`.
- Health & cleanup: `doctor` (environment + store integrity), `clean` (prune orphan caches/backups; `--artifacts --force` also prunes unused themes/plugins/kittens).
- Interactive TUI: `ui` (alias `pick`) with preview + Enter/Esc confirmation. Version: `kittymgr --version`.

## Requirements

- A Swift 6.1+ toolchain (SwiftPM). macOS 13+ or Linux (glibc).
- Optional at runtime: `kitty` (config validation + live reload) and `git` (git
  sources); both degrade gracefully when absent — run `kittymgr doctor` to see what
  is available.

Portability: the domain logic is Foundation-only, and SHA-256 uses CryptoKit on
Apple platforms and [swift-crypto](https://github.com/apple/swift-crypto) on Linux.
Both platforms are exercised in CI on every push and pull request — build, the
full test suite, and the end-to-end smoke run on `macos-15` and in the official
`swift:6.1` container (swift-crypto 4.5 requires a Swift 6.1 toolchain, so
`swift:6.0` is not sufficient on Linux). See [Tests](#tests) for the local
Linux verification command.

## Quickstart

```sh
swift build
.build/debug/kittymgr init           # attach the managed include block
.build/debug/kittymgr create work    # create a profile
#   add .conf snippets under kittymgr/profiles/work/, then:
.build/debug/kittymgr switch work    # validate, apply atomically, reload kitty
.build/debug/kittymgr ui             # or drive everything from the TUI
```

Nothing is irreversible: every mutating command snapshots first, `--dry-run`
previews any change as a unified diff, and `backup restore <id>` rolls back.

## Build & install

```sh
swift build                        # debug build at .build/debug/kittymgr
swift build -c release             # optimized build at .build/release/kittymgr
install -m 0755 .build/release/kittymgr /usr/local/bin/kittymgr   # put it on PATH
kittymgr --version
```

## Usage

```sh
# Create the managed layer and inject the guarded include block.
kittymgr init

# Remove the guarded block and restore kitty.conf to its pre-init state.
kittymgr uninstall

# Also delete the managed directory.
kittymgr uninstall --purge

# Profiles.
kittymgr list                 # List stored profiles.
kittymgr create work          # Create an empty profile.
kittymgr delete work          # Delete a profile (prompts; --force/-f to skip).

# Activation.
kittymgr switch work          # Activate a profile and reload kitty.
kittymgr current              # Print the active profile.

# Plugins (per-profile).
kittymgr plugin list                          # List plugins and enabled state.
kittymgr plugin enable theme-sample           # Enable for the active profile.
kittymgr plugin disable theme-sample --profile work

# Backups, history, and preview.
kittymgr backup create --label demo           # Snapshot the managed surface.
kittymgr backup list                          # List snapshots (id, timestamp, label).
kittymgr backup restore <id>                  # Restore a snapshot byte-for-byte.
kittymgr backup restore <id> --dry-run        # Preview the restore as a unified diff.

# Atomic re-apply of the active profile (validate; rollback on failure).
kittymgr apply
kittymgr apply --dry-run                       # Preview as a unified diff.

# Modular blocks (compose on top of the active profile).
kittymgr theme install gruvbox                 # From the built-in kitty-themes catalog.
kittymgr theme search gruv                     # Search the catalog.
kittymgr theme install mytheme --git <url>     # Or from any git/URL source.
kittymgr theme switch gruvbox                  # One active theme at a time.
kittymgr key add 'ctrl+shift+e launch --type=tab'
kittymgr snippet add tabs --from tabs.conf

# Kittens (scripts; isolated, never executed by kittymgr).
kittymgr kitten install hello --from ./hello.py
kittymgr kitten list                           # Prints the explicit invocation command.
kittymgr kitten remove hello

# Declarative config: describe everything in kittymgr.toml, then reconcile.
kittymgr manifest init                         # Bootstrap the manifest from current state.
kittymgr source add themes --git <url>         # Register a named remote source.
kittymgr sync --dry-run                        # Preview disk -> manifest reconciliation.
kittymgr sync                                  # Apply it (snapshot; rollback on failure).
kittymgr update                                # Re-resolve sources, re-pin kittymgr/kittymgr.lock, sync.
kittymgr update --check                        # Report which sources have newer commits (writes nothing).

# Health and cleanup.
kittymgr doctor                                # Environment + managed-store health (OK/WARN/FAIL).
kittymgr clean                                 # Remove orphan source caches and backup objects.
kittymgr clean --artifacts --force             # Also prune themes/plugins/kittens nothing references.

# Interactive terminal UI for switch, plugin/theme toggles, restore, sync, update, and conservative clean.
kittymgr ui                                  # Shows dry-run diff; Enter applies, Esc cancels.

# Every command also accepts --help.
kittymgr --help
```

The global `--dry-run` flag previews a change as a unified diff and writes
nothing. Snapshots are kept under `kittymgr/backups/` as content-addressed objects
plus one JSON manifest per snapshot; the manifest is published with an atomic
rename, so an interrupted snapshot never leaves a partial entry in the history.

`kittymgr ui` requires an interactive TTY. When stdin/stdout are piped, it exits
with an error before rendering or writing; use the equivalent CLI command with
`--dry-run` for CI or scripts. Profile creation/deletion, manifest editing, and
`clean --artifacts` stay on the CLI.

## How it works

`init` performs the following, atomically and idempotently:

1. Resolves the kitty config directory.
2. Creates `<config>/kittymgr/` and an empty `kittymgr/active.conf` entry point.
3. Backs up an existing `kitty.conf` to `kittymgr/backups/conf/kitty.conf.bak.<timestamp>`.
4. Inserts one guarded block at the **top** of `kitty.conf`:

   ```
   # >>> kittymgr (managed) >>>
   # Managed by kittymgr. Do not edit inside these markers.
   include kittymgr/active.conf
   # <<< kittymgr (managed) <<<
   ```

The block is placed at the top so the managed `include` is evaluated before the
user's own settings. kitty applies options last-wins, so the user's `kitty.conf`
retains final precedence over every managed layer.

Re-running `init` detects the existing markers and makes no changes. If a legacy
`managed/` layout is present and `kittymgr/` is absent, `init` migrates it by
renaming `managed/` to `kittymgr/`, moving a root `kittymgr.lock` to
`kittymgr/kittymgr.lock`, and rewriting only the guarded anchor in `kitty.conf`.
Other commands refuse to operate on the legacy layout and instruct you to run
`kittymgr init` first. `kittymgr.toml` remains at the config directory root
because it is user-owned input, not generated tool state.

`uninstall` removes only the guarded block, restoring the surrounding content
byte-for-byte. If `init` created `kitty.conf` (none existed before), `uninstall`
removes the file entirely.

## Profiles

A profile is a folder of `.conf` snippets under the managed directory:

```
kittymgr/profiles/<name>/*.conf
```

`create` makes an empty profile directory; add `.conf` files to it. An empty
profile is valid and contributes no settings. Names are restricted to
`A-Z a-z 0-9 . _ -`, must not start with `.`, and may not contain path
separators or traversal.

`switch <name>` regenerates `kittymgr/active.conf` (a small generated file, not a
symlink), records the selection in `kittymgr/.kittymgr-active`, and triggers a live
reload via `kitten @ load-config`. When kitty remote control is unavailable, the
switch is still persisted and manual reload instructions are printed (non-fatal).
`current` prints the active profile.

## Plugins

A plugin is a reusable, composable bundle of `.conf` snippets under the managed
directory:

```
kittymgr/plugins/<name>/*.conf
kittymgr/plugins/<name>/plugin.meta   # optional: priority=<int>
```

Plugins are enabled per-profile (stored in `kittymgr/profiles/<name>/profile.json`),
so the same plugin can be on for one profile and off for another. `init` seeds a
sample `theme-sample` plugin.

`active.conf` is always regenerated from scratch in a deterministic order, so
disabling a plugin leaves no residual lines:

1. profile base snippets — `profiles/<profile>/*.conf` (lexical)
2. enabled plugins — `plugins/<plugin>/*.conf`, plugins ordered by `priority`
   ascending then name; higher priority wins
3. the user's `kitty.conf` settings (after the managed `include`) win over all of
   the above

`plugin enable`/`plugin disable` apply to the active profile by default, or to
`--profile <name>`. Changes to the active profile regenerate `active.conf` and
reload immediately.

## Declarative manifest (kittymgr.toml)

`kittymgr.toml` describes the reproducible configuration as code (schema v2). A v1
manifest (without `schema_version` or the artifact tables) still loads and is
migrated to v2 on the next write.

```toml
[settings]
schema_version = 2
active_profile = "work"
active_theme   = "gruvbox"
keys           = ["ctrl-shift-e"]   # slugs; content lives in kittymgr/keys/<slug>.conf
snippets       = ["tabs"]           # slugs; content lives in kittymgr/snippets/<slug>.conf

[profiles.work]
plugins = ["theme-sample"]

[[sources]]
name = "kitty-themes"
git  = "https://github.com/kovidgoyal/kitty-themes"

[[themes]]
name = "gruvbox"
from = "kitty-themes"
```

`manifest init` bootstraps the file from the current on-disk state. Installed
themes/plugins/kittens are written with an empty `from` (their origin is not
recorded on disk) and a note asks you to set each `from` to a `[[sources]]` name;
once set, `sync` installs any missing artifact before reconciling. `keys` and
`snippets` are captured by slug — their content stays in
`kittymgr/keys|snippets/<slug>.conf`, so commit those files to reproduce it.

## Config directory resolution

Resolved in order:

1. `KITTY_CONFIG_DIRECTORY`
2. `$XDG_CONFIG_HOME/kitty`
3. `~/.config/kitty`

The resolved path is printed on every run for confirmation.

## Tests

```sh
swift test          # full suite (Swift Testing)
scripts/smoke.sh    # end-to-end smoke against a throwaway KITTY_CONFIG_DIRECTORY
```

Linux, reproduced locally the same way CI runs it (build, full suite, and smoke):

```sh
docker run --rm -v "$PWD":/app -w /app swift:6.1 bash -lc \
  'swift build --build-path .build-linux && swift test --build-path .build-linux \
   && KITTYMGR_BIN=.build-linux/debug/kittymgr scripts/smoke.sh'
```

The separate `--build-path` keeps Linux build artifacts out of the host `.build/`.

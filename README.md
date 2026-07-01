# kittymgr

A non-invasive configuration manager for the [kitty](https://sw.kovidgoyal.net/kitty/)
terminal. kittymgr never rewrites a user's `kitty.conf`; it attaches a single,
clearly fenced `include` block and keeps all managed state in a dedicated
`managed/` subdirectory. Every change is backed up, idempotent, and reversible.

## Status

- Managed layer: `init`, `uninstall`.
- Profiles: `list`, `create`, `delete`, `switch`, `current` (also under the `profile` verb).
- Plugins (per-profile config snippets): `plugin list/enable/disable`.
- Backups & preview: `backup create/list/restore`, plus a global `--dry-run` flag.
- Atomic apply with rollback: `apply` (snapshot → write → validate → reload/rollback).
- Modular blocks: `theme`, `key`, `snippet`.
- Kittens (isolated scripts, never auto-run): `kitten list/install/remove`.
- Remote sources: install themes/plugins/kittens from git/URL; `theme install <name>` pulls from the built-in catalog.
- Declarative config: `kittymgr.toml` manifest, `manifest init/show`, `source add/list/remove`.
- Reconcile & pin: `sync` (disk ↔ manifest, snapshot + rollback), `update` (refresh sources), `kittymgr.lock`.
- Interactive TUI: `ui` (alias `pick`).

## Quickstart

```sh
swift build
.build/debug/kittymgr init           # attach the managed include block
.build/debug/kittymgr create work    # create a profile
#   add .conf snippets under managed/profiles/work/, then:
.build/debug/kittymgr switch work    # validate, apply atomically, reload kitty
.build/debug/kittymgr ui             # or drive everything from the TUI
```

Nothing is irreversible: every mutating command snapshots first, `--dry-run`
previews any change as a unified diff, and `backup restore <id>` rolls back.

## Build

```sh
swift build
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
kittymgr update                                # Re-resolve sources, re-pin kittymgr.lock, sync.

# Interactive terminal UI over all of the above.
kittymgr ui

# Every command also accepts --help.
kittymgr --help
```

The global `--dry-run` flag previews a change as a unified diff and writes
nothing. Snapshots are kept under `managed/backups/` as content-addressed objects
plus one JSON manifest per snapshot; the manifest is published with an atomic
rename, so an interrupted snapshot never leaves a partial entry in the history.

## How it works

`init` performs the following, atomically and idempotently:

1. Resolves the kitty config directory.
2. Creates `<config>/managed/` and an empty `managed/active.conf` entry point.
3. Backs up an existing `kitty.conf` to `kitty.conf.bak.<timestamp>`.
4. Inserts one guarded block at the **top** of `kitty.conf`:

   ```
   # >>> kittymgr (managed) >>>
   # Managed by kittymgr. Do not edit inside these markers.
   include managed/active.conf
   # <<< kittymgr (managed) <<<
   ```

The block is placed at the top so the managed `include` is evaluated before the
user's own settings. kitty applies options last-wins, so the user's `kitty.conf`
retains final precedence over every managed layer.

Re-running `init` detects the existing markers and makes no changes.

`uninstall` removes only the guarded block, restoring the surrounding content
byte-for-byte. If `init` created `kitty.conf` (none existed before), `uninstall`
removes the file entirely.

## Profiles

A profile is a folder of `.conf` snippets under the managed directory:

```
managed/profiles/<name>/*.conf
```

`create` makes an empty profile directory; add `.conf` files to it. An empty
profile is valid and contributes no settings. Names are restricted to
`A-Z a-z 0-9 . _ -`, must not start with `.`, and may not contain path
separators or traversal.

`switch <name>` regenerates `managed/active.conf` (a small generated file, not a
symlink), records the selection in `managed/.kittymgr-active`, and triggers a live
reload via `kitten @ load-config`. When kitty remote control is unavailable, the
switch is still persisted and manual reload instructions are printed (non-fatal).
`current` prints the active profile.

## Plugins

A plugin is a reusable, composable bundle of `.conf` snippets under the managed
directory:

```
managed/plugins/<name>/*.conf
managed/plugins/<name>/plugin.meta   # optional: priority=<int>
```

Plugins are enabled per-profile (stored in `managed/profiles/<name>/profile.json`),
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

## Config directory resolution

Resolved in order:

1. `KITTY_CONFIG_DIRECTORY`
2. `$XDG_CONFIG_HOME/kitty`
3. `~/.config/kitty`

The resolved path is printed on every run for confirmation.

## Tests

```sh
swift test
```


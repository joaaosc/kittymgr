# kittymgr

A non-invasive configuration manager for the [kitty](https://sw.kovidgoyal.net/kitty/)
terminal. kittymgr never rewrites a user's `kitty.conf`; it attaches a single,
clearly fenced `include` block and keeps all managed state in a dedicated
`managed/` subdirectory. Every change is backed up, idempotent, and reversible.

## Status

- M01 — managed layer bootstrap: `init`, `uninstall`.
- M02 — profile model & storage: `list`, `create`, `delete`.
- M03 — switch active profile: `switch`, `current`.
- M04 — plugins & composition: `plugin list/enable/disable`.

Later milestones add backups/history, validation, and a TUI.

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
```

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
retains final precedence over every managed layer (see `docs/adr/0002`).

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

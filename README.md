# kittymgr

A non-invasive configuration manager for the [kitty](https://sw.kovidgoyal.net/kitty/)
terminal. kittymgr never rewrites a user's `kitty.conf`; it attaches a single,
clearly fenced `include` block and keeps all managed state in a dedicated
`managed/` subdirectory. Every change is backed up, idempotent, and reversible.

## Status

M01 — managed layer bootstrap: `init` and `uninstall`. Later milestones add
backups/history, profile switching, plugins, validation, and a TUI.

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
```

## How it works

`init` performs the following, atomically and idempotently:

1. Resolves the kitty config directory.
2. Creates `<config>/managed/` and an empty `managed/active.conf` entry point.
3. Backs up an existing `kitty.conf` to `kitty.conf.bak.<timestamp>`.
4. Appends one guarded block to `kitty.conf`:

   ```
   # >>> kittymgr (managed) >>>
   # Managed by kittymgr. Do not edit inside these markers.
   include managed/active.conf
   # <<< kittymgr (managed) <<<
   ```

Re-running `init` detects the existing markers and makes no changes.

`uninstall` removes only the guarded block, restoring the surrounding content
byte-for-byte. If `init` created `kitty.conf` (none existed before), `uninstall`
removes the file entirely.

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

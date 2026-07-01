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
kittymgr theme install gruvbox --from gruvbox.conf
kittymgr theme switch gruvbox                  # One active theme at a time.
kittymgr key add 'ctrl+shift+e launch --type=tab'
kittymgr snippet add tabs --from tabs.conf

# Kittens (scripts; isolated, never executed by kittymgr).
kittymgr kitten install hello --from ./hello.py
kittymgr kitten list                           # Prints the explicit invocation command.
kittymgr kitten remove hello

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

## Implementation notes

Per-feature technical record of how each capability is built.

### Backups, history, and dry-run

The backup subsystem keeps its own content-addressed snapshots rather than
embedding git: no runtime dependency on a `git` binary, deterministic and
portable, with free deduplication of unchanged files. The store lives under
`managed/backups/`:

- `objects/<sha256>` — unique file contents (one blob per distinct content),
  written before the manifest via `Data.write(.atomic)`.
- `snapshots/<id>.json` — one manifest per snapshot (`id`, ISO-8601 `createdAt`,
  optional `label`, and the list of `{path, sha256, size}`), published last.

The tracked surface is `kitty.conf` plus every regular file under `managed/`,
excluding the backup store itself. The set of published manifests *is* the
history, so `list()` just enumerates `snapshots/*.json`. Atomicity comes from the
manifest write being the single publish point: a crash before that atomic rename
leaves only orphan objects, never a partial history entry. Restore rewrites every
file recorded in a manifest and removes any file added since, reproducing the
snapshot byte-for-byte (verified by checksum). Snapshot ids are
`yyyyMMdd-HHmmss-SSS` (with a collision counter) so they sort chronologically and
accept a unique prefix on `restore`.

`--dry-run` is a cross-cutting flag stripped by the dispatcher before command
parsing. `backup` consumes it natively to print a unified diff and exit without
writing; other mutating commands short-circuit to a no-op under `--dry-run` until
they route through the apply pipeline. The diff engine is a dependency-free
Longest-Common-Subsequence implementation that emits standard unified-diff hunks
(`@@`/`±` context) and a per-file `a/` ↔ `b/` (or `/dev/null`) header for
added/removed/modified files.

### Validation, atomic apply, and rollback

`ApplyTransaction` is the transactional primitive that write features build on:
snapshot → atomic write → validate → reload, with rollback on failure. A change
is materialized as an `ApplyPlan` (relative-path writes and deletes). On a real
apply it captures a `pre-apply` snapshot, writes the plan atomically (temp +
rename per file), then validates the *composed* configuration with kitty. If
validation fails, the managed surface is restored from the pre-apply snapshot
byte-for-byte and `SafetyError.invalidConfiguration` is thrown, so the live
session is never asked to reload a rejected config; on pass (or when validation is
unavailable and degrades to skipped) the change is kept and a live reload is
triggered. Validation runs *after* the write so what kitty checks is exactly what
sits on disk. `--dry-run` short-circuits before any write: it diffs the plan
against the current surface and runs validation as a non-committing preview
(validation writes only its own temp file). Validation reuses the existing
`KittyConfigValidator` (`kitty --debug-config`, degrading to skipped on kitty
versions that lack the flag) and reload reuses `KittenReloader`. The user-facing
`apply` command re-composes and re-applies the active profile through this
pipeline — useful after editing profile/plugin `.conf` files by hand.

### Named profiles routed through the apply pipeline

Switching a profile composes it once (via `ProfileComposer`, shared by `switch`
and `apply`): it builds the ordered `include` list, renders `active.conf`, inlines
the layers for validation, and detects conflicts — returning a single
`ApplyPlan`. `switch` gates on conflicts up front (`--force` to override), then
hands the plan to `ApplyTransaction`, so a switch is now snapshot-protected: an
invalid composition rolls back to the pre-apply snapshot and the active pointer is
moved only after the apply is kept. A rejected or dry-run switch therefore leaves
the previous selection intact. The transaction needs the config root to snapshot
the whole managed surface; it is recovered from the canonical location of
`active.conf` (`<configDir>/managed/active.conf`). The user `kitty.conf` body is
never touched — only the generated `managed/active.conf` changes — so switching is
non-destructive and round-trips byte-for-byte. The same operations are also
exposed under a `profile` verb (`profile list/create/switch/delete/current`)
alongside the original top-level commands.

### Modular themes, keybindings, and snippets

Three block types layer on top of any profile, each in its own include file:

```
managed/themes/<name>.conf      # installed themes; one active at a time
managed/keys/<slug>.conf        # keybinding includes (additive)
managed/snippets/<slug>.conf    # snippet includes (additive)
managed/.kittymgr-theme         # name of the active theme
```

`BlockStore` reads the active block set from disk (the active theme plus the
present key/snippet slugs). `BlockComposer` turns a `BlockChange`
(install/switch/remove a theme, add/remove a keybinding or snippet) into file
writes/deletes plus the `include` lines and layers the blocks contribute, keeping
pending content in an in-memory overlay so a `--dry-run` composes the post-change
`active.conf` without touching disk. Composition is centralized in
`ProfileComposer`, which appends the block contribution after the profile's base
snippets and plugins (order: theme → snippets → keys) — so `switch`, `apply`,
`check`, and plugin reactivation all carry the active blocks, and themes survive a
profile switch. Every block mutation flows through the same `ApplyTransaction`
(snapshot → write → validate → reload/rollback), so an invalid block is rejected
and rolled back. Themes are mutually exclusive (switching replaces the single
active theme include); keybindings and snippets are additive sets. The CLI exposes
`theme list/install/switch/remove`, `key list/add/remove`, and
`snippet list/add/remove`; `--from <file>` seeds a theme or snippet from an
existing file. Keybinding slugs are derived from the chord (`ctrl+shift+e` →
`ctrl-shift-e`).

### Kittens (isolated scripts)

Kittens — kitty's term for scripts run with `kitty +kitten` — are distinct from
config-snippet `plugin`s: a kitten is *code*, not a composed `.conf`. They are
managed under a separate `kitten` verb (`kitten list/install/remove`) to keep that
distinction explicit, and each is isolated in its own directory:

```
managed/kittens/<name>/            # the kitten's files
managed/kittens/<name>/.kitten.json # provenance: source, installed-at, checksum, entry
```

`KittenStore` only copies files: it stages into a temp directory and publishes with
an atomic rename, and it **never executes a kitten** — not on install, not on config
load. A kitten is therefore not added to `active.conf`; the user invokes it
explicitly (`kitty +kitten managed/kittens/<name>/<entry>`), and `kitten list`
prints that command. Install records provenance (the source path and, for a
single-file kitten, a SHA-256 checksum) in `.kitten.json`. Because the kittens
directory is part of the snapshot surface, every `install`/`remove` first takes a
labeled snapshot (`kitten-install-<name>` / `kitten-remove-<name>`), so the history
records exactly what third-party code entered the configuration and when, and the
change is reversible with `backup restore`. `--dry-run` reports the effect without
copying or snapshotting.

### Interactive TUI

`ui` (alias `pick`) is a thin presentation layer over the same core commands —
`SwitchCommand`, `PluginCommand`, `BlockCommand`, `BackupCommand` — so it never
reimplements logic and inherits every safety guarantee. It is a cooked-mode menu
loop (no raw mode, no dependencies), so startup is effectively instant and it can
never leave the terminal in a broken state; IO is injected, which makes the whole
controller testable without a real terminal. One screen lists profiles, plugins,
themes, the snapshot count, and kittens; commands switch profiles (`<n>` / `f <n>`
to force), toggle plugins (`t <name>`), switch themes (`theme <name>`), snapshot
(`snap [label]`), and restore. Destructive restores are previewable: `restore <id>`
(and `diff <id>`) print the unified `--dry-run` diff and change nothing, while
`restore! <id>` applies it — so the visual diff always precedes the write. The
config root needed by the block/backup/kitten subsystems is recovered from the
canonical location of `active.conf`, so the picker keeps its original constructor.
`--help` (and `<command> --help`) prints the full command surface.

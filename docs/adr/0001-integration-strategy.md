# ADR 0001 — Integration strategy

Status: Accepted

## Context

kittymgr must attach managed configuration to an existing kitty setup that the
user already owns and edits by hand. The attachment mechanism is depended upon by
every later milestone (backups, profile switching, plugins, validation), so it
must be safe, idempotent, and fully reversible. Three approaches were considered:

1. **Single guarded `include` block** appended to the user's `kitty.conf`.
2. **Symlinking the whole config directory** to a tool-controlled location.
3. **Generating a full `kitty.conf`** from a managed source of truth.

## Decision

Use a single guarded `include` block.

- The block is delimited by stable, namespaced markers
  (`# >>> kittymgr (managed) >>>` … `# <<< kittymgr (managed) <<<`) that are
  unlikely to collide with hand-written comments.
- Content outside the markers is never modified. Inserting the block adds lines
  only; removing it restores the surrounding bytes exactly.
- A timestamped backup is taken before the first edit, and writes are atomic
  (temp file + rename) to survive interruption.
- Sidecar state (`managed/.kittymgr-meta`) records whether kittymgr created the
  file and whether a terminating newline was added, so `uninstall` is an exact
  inverse of `init`.

## Consequences

- **Trust and reversibility:** users keep ownership of `kitty.conf`; the managed
  layer is one visible, removable block.
- **Precedence:** kitty applies settings positionally, so an appended `include`
  layers after most user settings. Final precedence handling is deferred to M04;
  this milestone documents the appended-at-end assumption.
- Rejected (2) symlinking — too invasive and fragile across platforms and breaks
  the user's expectation of editing a normal file. Rejected (3) full generation —
  would require kittymgr to own and reproduce the entire config, which is high
  risk and hard to trust.

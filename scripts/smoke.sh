#!/usr/bin/env bash
# End-to-end smoke against a throwaway KITTY_CONFIG_DIRECTORY:
# init -> create -> switch --dry-run -> switch -> uninstall.
# Asserts the safety invariants from the outside: dry-run mutates nothing,
# switch flips the active pointer, uninstall removes only the managed anchor
# and preserves user content. Runs without kitty installed (validation and
# live reload degrade to skipped/unavailable).
set -euo pipefail

BIN="${KITTYMGR_BIN:-$(swift build --show-bin-path)/kittymgr}"
if [ ! -x "$BIN" ]; then
  echo "error: kittymgr binary not found at '$BIN' (run swift build, or set KITTYMGR_BIN)" >&2
  exit 1
fi

TMP_KITTY="$(mktemp -d)"
export KITTY_CONFIG_DIRECTORY="$TMP_KITTY"
trap 'rm -rf "$TMP_KITTY"' EXIT

# Keep the smoke hermetic: without these, `kitten @ load-config` cannot reach
# a live kitty, so a locally running kitty is never touched and the reload
# path degrades exactly like in CI.
unset KITTY_LISTEN_ON KITTY_PID KITTY_WINDOW_ID

fail() {
  echo "SMOKE FAIL: $1" >&2
  exit 1
}

# Byte-level digest of every file under $1 (paths + contents).
tree_digest() {
  (
    cd "$1"
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(cksum < "$f")"
    done
  )
}

printf 'font_size 14\n' > "$TMP_KITTY/kitty.conf"

echo "== init =="
"$BIN" init
grep -q 'include kittymgr/active.conf' "$TMP_KITTY/kitty.conf" \
  || fail "init did not write the kitty.conf anchor"

echo "== create work =="
"$BIN" create work

echo "== switch --dry-run (must not mutate) =="
before="$(tree_digest "$TMP_KITTY")"
"$BIN" switch work --dry-run
after="$(tree_digest "$TMP_KITTY")"
if [ "$before" != "$after" ]; then
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  fail "switch --dry-run mutated the config tree"
fi

echo "== switch work =="
"$BIN" switch work
[ "$(cat "$TMP_KITTY/kittymgr/.kittymgr-active")" = "work" ] \
  || fail "active pointer does not point at 'work'"
grep -q '# Active profile: work' "$TMP_KITTY/kittymgr/active.conf" \
  || fail "active.conf was not rendered for 'work'"

echo "== uninstall =="
"$BIN" uninstall
if grep -q 'kittymgr' "$TMP_KITTY/kitty.conf"; then
  fail "uninstall left kittymgr references in kitty.conf"
fi
grep -q 'font_size 14' "$TMP_KITTY/kitty.conf" \
  || fail "uninstall did not preserve user content (font_size 14)"

echo "SMOKE OK"

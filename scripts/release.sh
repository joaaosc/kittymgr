#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh --dry-run

Builds the local R5a release artifact in dist/:
  - kittymgr-<version>-macos-universal.tar.gz
  - SHA256SUMS

This script does not create tags, push, publish releases, or write outside dist/.
USAGE
}

fail() {
  echo "error: $1" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

[ "$DRY_RUN" -eq 1 ] || fail "only --dry-run is supported in R5a; tag-based publishing is deferred"
[ "$(uname -s)" = "Darwin" ] || fail "R5a builds the macOS universal artifact on macOS; Linux packaging is deferred"

require_tool swift
require_tool lipo
require_tool tar
require_tool shasum
require_tool sed
require_tool grep

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]+)".*/\1/p' src/Version.swift)"
[ -n "$VERSION" ] || fail "could not read Kittymgr.version from src/Version.swift"

DIST="$REPO_ROOT/dist"
WORK="$DIST/.work"
BUILD_PATH="$WORK/build"
PACKAGE_ROOT="$WORK/package"
PACKAGE_DIR="$PACKAGE_ROOT/kittymgr-$VERSION-macos-universal"
ARTIFACT="kittymgr-$VERSION-macos-universal.tar.gz"
ARTIFACT_PATH="$DIST/$ARTIFACT"
CHECKSUMS="$DIST/SHA256SUMS"

mkdir -p "$DIST"
rm -rf "$WORK" "$ARTIFACT_PATH" "$CHECKSUMS"
mkdir -p "$PACKAGE_DIR"
mkdir -p "$WORK/clang-module-cache" "$WORK/tmp"
export CLANG_MODULE_CACHE_PATH="$WORK/clang-module-cache"
export TMPDIR="$WORK/tmp"

echo "== build macOS universal =="
swift build \
  --configuration release \
  --disable-sandbox \
  --disable-automatic-resolution \
  --manifest-cache local \
  --cache-path "$WORK/swiftpm-cache" \
  --config-path "$WORK/swiftpm-config" \
  --security-path "$WORK/swiftpm-security" \
  --arch arm64 \
  --arch x86_64 \
  --build-path "$BUILD_PATH"

BIN=""
for candidate in \
  "$BUILD_PATH/apple/Products/Release/kittymgr" \
  "$BUILD_PATH/out/Products/Release/kittymgr" \
  "$BUILD_PATH/release/kittymgr"
do
  if [ -x "$candidate" ]; then
    BIN="$candidate"
    break
  fi
done
[ -n "$BIN" ] || fail "release binary not found under $BUILD_PATH"
lipo -verify_arch arm64 "$BIN"
lipo -verify_arch x86_64 "$BIN"

install -m 0755 "$BIN" "$PACKAGE_DIR/kittymgr"
install -m 0644 LICENSE "$PACKAGE_DIR/LICENSE"
cat > "$PACKAGE_DIR/README.txt" <<EOF
kittymgr $VERSION for macOS universal (arm64 + x86_64)

Install:
  install -m 0755 kittymgr /usr/local/bin/kittymgr

Verify:
  kittymgr --version
EOF

find "$PACKAGE_DIR" -exec touch -t 202001010000.00 {} +

echo "== package =="
(
  cd "$PACKAGE_ROOT"
  COPYFILE_DISABLE=1 tar \
    --format ustar \
    --uid 0 \
    --gid 0 \
    --uname root \
    --gname wheel \
    -czf "$ARTIFACT_PATH" \
    "kittymgr-$VERSION-macos-universal"
)

echo "== checksums =="
(
  cd "$DIST"
  shasum -a 256 "$ARTIFACT" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)

echo "== smoke packaged artifact =="
SMOKE_ROOT="$WORK/smoke"
EXTRACT_ROOT="$SMOKE_ROOT/extract"
mkdir -p "$EXTRACT_ROOT"
tar -xzf "$ARTIFACT_PATH" -C "$EXTRACT_ROOT"
SMOKE_BIN="$EXTRACT_ROOT/kittymgr-$VERSION-macos-universal/kittymgr"
[ -x "$SMOKE_BIN" ] || fail "extracted binary not found"
"$SMOKE_BIN" --version | grep -qx "kittymgr $VERSION"
lipo -verify_arch arm64 "$SMOKE_BIN"
lipo -verify_arch x86_64 "$SMOKE_BIN"
KITTYMGR_BIN="$SMOKE_BIN" KITTYMGR_SMOKE_ROOT="$SMOKE_ROOT/config" "$SCRIPT_DIR/smoke.sh"

rm -rf "$WORK"

echo "== dry-run complete =="
echo "$ARTIFACT_PATH"
echo "$CHECKSUMS"

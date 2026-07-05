#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/release.sh --dry-run                  Build the macOS universal artifact into dist/
  scripts/release.sh --dry-run --linux          Build the Linux x86_64 artifact into dist/
                                                inside a disposable Docker container (swift:6.1)
  scripts/release.sh --dry-run --linux-aarch64  Build the Linux aarch64 artifact the same way
                                                (native on arm64 Docker hosts, e.g. Apple Silicon)

Artifacts written to dist/:
  kittymgr-<version>-macos-universal.tar.gz    (--dry-run)
  kittymgr-<version>-linux-x86_64.tar.gz       (--dry-run --linux)
  kittymgr-<version>-linux-aarch64.tar.gz      (--dry-run --linux-aarch64)
  SHA256SUMS    covers every kittymgr-<version>-*.tar.gz present in dist/

Linux mode requirements:
  - Docker Engine already running (this script does not start or install Docker)
  - Image swift:6.1 for the requested platform (pulled automatically on first use)
  Build, tests, packaging, and the smoke test all run inside `docker run --rm`
  with the repository mounted read-only at /workspace; dist/ is the only
  writable bind, and all build state stays under dist/.work.

This script does not create tags, push, publish releases, or write outside dist/.

Internal:
  --linux-container-stage    entry point executed inside the swift:6.1 container;
                             not intended for direct use on the host
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
LINUX=0
CONTAINER_STAGE=0
# The container stage learns its architecture through this variable, exported
# into the container by linux_release; on the host the flags below set it.
LINUX_ARCH="${KITTYMGR_LINUX_ARCH:-x86_64}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --linux)
      LINUX=1
      LINUX_ARCH="x86_64"
      ;;
    --linux-aarch64)
      LINUX=1
      LINUX_ARCH="aarch64"
      ;;
    --linux-container-stage)
      CONTAINER_STAGE=1
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

require_tool sed
require_tool grep

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(sed -nE 's/^[[:space:]]*public static let version = "([^"]+)".*/\1/p' src/Version.swift)"
[ -n "$VERSION" ] || fail "could not read Kittymgr.version from src/Version.swift"

DIST="$REPO_ROOT/dist"
WORK="$DIST/.work"
CHECKSUMS="$DIST/SHA256SUMS"
MACOS_ARTIFACT="kittymgr-$VERSION-macos-universal.tar.gz"
DOCKER_IMAGE="swift:6.1"
case "$LINUX_ARCH" in
  x86_64)
    DOCKER_PLATFORM="linux/amd64"
    ELF_MACHINE="X86-64"
    ;;
  aarch64)
    DOCKER_PLATFORM="linux/arm64"
    ELF_MACHINE="AArch64"
    ;;
  *)
    fail "unsupported Linux architecture: $LINUX_ARCH"
    ;;
esac
LINUX_ARTIFACT="kittymgr-$VERSION-linux-$LINUX_ARCH.tar.gz"

# SHA256SUMS always covers every current-version artifact present in dist/, so
# after running all modes it lists macOS universal and every Linux arch together.
write_checksums() {
  (
    cd "$DIST"
    set -- kittymgr-"$VERSION"-*.tar.gz
    [ -e "$1" ] || fail "no kittymgr-$VERSION-*.tar.gz artifacts found in dist/"
    shasum -a 256 "$@" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
  )
}

macos_release() {
  [ "$(uname -s)" = "Darwin" ] || fail "the macOS universal artifact must be built on macOS; use --linux for the Linux x86_64 artifact"
  require_tool swift
  require_tool lipo
  require_tool tar
  require_tool shasum

  local BUILD_PATH="$WORK/build"
  local PACKAGE_ROOT="$WORK/package"
  local PACKAGE_DIR="$PACKAGE_ROOT/kittymgr-$VERSION-macos-universal"
  local ARTIFACT_PATH="$DIST/$MACOS_ARTIFACT"

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

  local BIN=""
  local candidate
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
  write_checksums

  echo "== smoke packaged artifact =="
  local SMOKE_ROOT="$WORK/smoke"
  local EXTRACT_ROOT="$SMOKE_ROOT/extract"
  mkdir -p "$EXTRACT_ROOT"
  tar -xzf "$ARTIFACT_PATH" -C "$EXTRACT_ROOT"
  local SMOKE_BIN="$EXTRACT_ROOT/kittymgr-$VERSION-macos-universal/kittymgr"
  [ -x "$SMOKE_BIN" ] || fail "extracted binary not found"
  "$SMOKE_BIN" --version | grep -qx "kittymgr $VERSION"
  lipo -verify_arch arm64 "$SMOKE_BIN"
  lipo -verify_arch x86_64 "$SMOKE_BIN"
  KITTYMGR_BIN="$SMOKE_BIN" KITTYMGR_SMOKE_ROOT="$SMOKE_ROOT/config" "$SCRIPT_DIR/smoke.sh"

  rm -rf "$WORK"

  echo "== dry-run complete =="
  echo "$ARTIFACT_PATH"
  echo "$CHECKSUMS"
}

linux_release() {
  require_tool docker
  require_tool shasum
  docker version >/dev/null 2>&1 \
    || fail "Docker Engine is not running (docker version failed); start it and retry"

  mkdir -p "$DIST"
  rm -rf "$WORK" "$DIST/$LINUX_ARTIFACT" "$CHECKSUMS"
  mkdir -p "$WORK"

  echo "== docker preflight ($DOCKER_IMAGE, $DOCKER_PLATFORM) =="
  docker run --rm --platform "$DOCKER_PLATFORM" "$DOCKER_IMAGE" swift --version

  # The repository is mounted read-only; dist/ is the only writable bind, so
  # the container can prove at runtime that nothing outside dist/ is touched.
  echo "== linux $LINUX_ARCH build + test + package + smoke in disposable container =="
  docker run --rm \
    --platform "$DOCKER_PLATFORM" \
    --volume "$REPO_ROOT:/workspace:ro" \
    --volume "$DIST:/workspace/dist" \
    --env KITTYMGR_LINUX_ARCH="$LINUX_ARCH" \
    --workdir /workspace \
    "$DOCKER_IMAGE" \
    bash scripts/release.sh --linux-container-stage

  [ -f "$DIST/$LINUX_ARTIFACT" ] || fail "container stage did not produce dist/$LINUX_ARTIFACT"

  echo "== checksums =="
  write_checksums

  rm -rf "$WORK"

  echo "== dry-run complete =="
  echo "$DIST/$LINUX_ARTIFACT"
  echo "$CHECKSUMS"
}

# Runs inside the swift:6.1 Linux container for $LINUX_ARCH with the repo
# mounted read-only at /workspace (dist/ is the only writable bind).
# The release binary links the Swift runtime statically (-Xswiftc -static-stdlib)
# so the artifact does not require a Swift toolchain on the target host; the
# remaining dynamic dependencies (glibc family, loader) are printed via ldd.
linux_container_stage() {
  [ "$(uname -s)" = "Linux" ] || fail "--linux-container-stage runs only inside the Linux container"
  [ "$(uname -m)" = "$LINUX_ARCH" ] || fail "container is $(uname -m), expected $LINUX_ARCH"
  require_tool swift
  require_tool tar
  require_tool gzip
  require_tool readelf
  require_tool ldd

  local BUILD_PATH="$WORK/linux-build"
  local PACKAGE_ROOT="$WORK/linux-package"
  local PACKAGE_NAME="kittymgr-$VERSION-linux-$LINUX_ARCH"
  local PACKAGE_DIR="$PACKAGE_ROOT/$PACKAGE_NAME"
  local ARTIFACT_PATH="$DIST/$LINUX_ARTIFACT"

  mkdir -p "$PACKAGE_DIR"

  local -a SWIFTPM_FLAGS=(
    --disable-sandbox
    --disable-automatic-resolution
    --manifest-cache local
    --cache-path "$WORK/linux-swiftpm-cache"
    --config-path "$WORK/linux-swiftpm-config"
    --security-path "$WORK/linux-swiftpm-security"
    --build-path "$BUILD_PATH"
  )

  echo "== [container] toolchain =="
  swift --version

  echo "== [container] swift test =="
  swift test "${SWIFTPM_FLAGS[@]}"

  echo "== [container] swift build --configuration release -Xswiftc -static-stdlib =="
  swift build --configuration release "${SWIFTPM_FLAGS[@]}" -Xswiftc -static-stdlib

  local BIN
  BIN="$(swift build --configuration release "${SWIFTPM_FLAGS[@]}" -Xswiftc -static-stdlib --show-bin-path)/kittymgr"
  [ -x "$BIN" ] || fail "release binary not found at $BIN"
  readelf -h "$BIN" | grep -q "$ELF_MACHINE" || fail "release binary is not $LINUX_ARCH"

  install -m 0755 "$BIN" "$PACKAGE_DIR/kittymgr"
  install -m 0644 LICENSE "$PACKAGE_DIR/LICENSE"
  cat > "$PACKAGE_DIR/README.txt" <<EOF
kittymgr $VERSION for Linux $LINUX_ARCH

Install:
  install -m 0755 kittymgr /usr/local/bin/kittymgr

Verify:
  kittymgr --version
EOF

  echo "== [container] package =="
  (
    cd "$PACKAGE_ROOT"
    tar \
      --format ustar \
      --sort=name \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --mtime='2020-01-01 00:00:00 UTC' \
      -cf - "$PACKAGE_NAME" | gzip -n > "$WORK/$LINUX_ARTIFACT.tmp"
  )
  mv "$WORK/$LINUX_ARTIFACT.tmp" "$ARTIFACT_PATH"

  echo "== [container] smoke packaged artifact =="
  local SMOKE_ROOT="$WORK/linux-smoke"
  local EXTRACT_ROOT="$SMOKE_ROOT/extract"
  mkdir -p "$EXTRACT_ROOT"
  tar -xzf "$ARTIFACT_PATH" -C "$EXTRACT_ROOT"
  local SMOKE_BIN="$EXTRACT_ROOT/$PACKAGE_NAME/kittymgr"
  [ -x "$SMOKE_BIN" ] || fail "extracted binary not found"
  local REPORTED_VERSION
  REPORTED_VERSION="$("$SMOKE_BIN" --version)"
  echo "$REPORTED_VERSION"
  [ "$REPORTED_VERSION" = "kittymgr $VERSION" ] || fail "unexpected --version output: $REPORTED_VERSION"
  readelf -h "$SMOKE_BIN" | grep -q "$ELF_MACHINE" || fail "extracted binary is not $LINUX_ARCH"

  echo "== [container] remaining runtime dependencies (ldd) =="
  ldd "$SMOKE_BIN"

  KITTYMGR_BIN="$SMOKE_BIN" KITTYMGR_SMOKE_ROOT="$SMOKE_ROOT/config" "$SCRIPT_DIR/smoke.sh"
}

if [ "$CONTAINER_STAGE" -eq 1 ]; then
  linux_container_stage
  exit 0
fi

[ "$DRY_RUN" -eq 1 ] || fail "only --dry-run is supported; tag-based publishing is handled by .github/workflows/release.yml"

if [ "$LINUX" -eq 1 ]; then
  linux_release
else
  macos_release
fi

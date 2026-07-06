#!/bin/sh
# Installer for kittymgr release binaries. POSIX sh on purpose: it must run
# under dash (`sh install.sh` on Debian/Ubuntu) as well as bash/zsh.
#
# Downloads the platform tarball and SHA256SUMS from GitHub Releases (or reads
# them from a local artifact directory), verifies the checksum — verification
# is mandatory, a mismatch always aborts — and installs the single binary into
# <prefix>/bin/kittymgr atomically. It never invokes sudo (an unwritable
# prefix is an error, not an escalation), never pipes remote code into a
# shell (artifacts are downloaded to files and verified before anything is
# executed), writes only inside the chosen prefix, and is idempotent:
# reinstalling the version that is already present is a reported no-op.

set -eu


REPO_SLUG="joaaosc/kittymgr"

usage() {
  cat <<'USAGE'
Usage:
  install.sh [--dry-run] [--prefix DIR] [--version X.Y.Z] [--artifact-dir DIR]

Options:
  --dry-run           Print platform, release, source, and target; write nothing.
  --prefix DIR        Install prefix (default: ~/.local). The binary is written
                      to DIR/bin/kittymgr and nothing else is touched.
  --version X.Y.Z     Release to install (default: the latest GitHub release).
                      A leading "v" is accepted.
  --artifact-dir DIR  Install from local artifacts (kittymgr-<version>-*.tar.gz
                      plus SHA256SUMS, e.g. dist/) instead of downloading.
                      Nothing is written into DIR.
  -h, --help          Show this help.

Checksum verification against SHA256SUMS is mandatory in both modes.
This script never uses sudo; pick a writable --prefix instead.

Uninstall:
  1. kittymgr uninstall        # removes the managed block from kitty.conf
  2. rm <prefix>/bin/kittymgr  # or `brew uninstall kittymgr` if installed via brew
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
PREFIX="$HOME/.local"
VERSION=""
ARTIFACT_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --prefix)
      [ "$#" -ge 2 ] || fail "--prefix requires a directory argument"
      PREFIX="$2"
      shift
      ;;
    --version)
      [ "$#" -ge 2 ] || fail "--version requires a version argument"
      VERSION="${2#v}"
      shift
      ;;
    --artifact-dir)
      [ "$#" -ge 2 ] || fail "--artifact-dir requires a directory argument"
      ARTIFACT_DIR="$2"
      shift
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

if [ -n "$VERSION" ]; then
  echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "--version must be X.Y.Z (got '$VERSION')"
fi
if [ -n "$ARTIFACT_DIR" ]; then
  [ -d "$ARTIFACT_DIR" ] || fail "--artifact-dir '$ARTIFACT_DIR' is not a directory"
fi

# sha256 checksums: shasum (macOS, perl) or sha256sum (coreutils); both accept
# the "<hash>  <file>" line format used by dist/SHA256SUMS.
if command -v shasum >/dev/null 2>&1; then
  sha256_check() { shasum -a 256 -c - >/dev/null; }
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_check() { sha256sum -c - >/dev/null; }
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
else
  fail "neither shasum nor sha256sum found; cannot verify checksums"
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin)
    SUFFIX="macos-universal"
    PLATFORM_LABEL="macos/universal"
    ;;
  Linux)
    case "$ARCH" in
      x86_64)
        SUFFIX="linux-x86_64"
        PLATFORM_LABEL="linux/x86_64"
        ;;
      aarch64|arm64)
        SUFFIX="linux-aarch64"
        PLATFORM_LABEL="linux/aarch64"
        ;;
      *)
        fail "unsupported Linux architecture: $ARCH"
        ;;
    esac
    ;;
  *)
    fail "unsupported operating system: $OS"
    ;;
esac

# linux-aarch64 artifacts are built locally (scripts/release.sh --dry-run
# --linux-aarch64) but not published to GitHub Releases yet, so the remote
# path cannot serve them.
if [ "$SUFFIX" = "linux-aarch64" ] && [ -z "$ARTIFACT_DIR" ]; then
  fail "linux-aarch64 artifacts are not published to GitHub Releases yet; build one locally and pass --artifact-dir"
fi

# Resolve the version: explicit flag > sole matching local artifact > latest
# GitHub release. The GitHub API call is a read-only GET and writes nothing.
if [ -z "$VERSION" ]; then
  if [ -n "$ARTIFACT_DIR" ]; then
    # Positional parameters double as the glob result; the original arguments
    # were fully consumed by the parse loop above.
    set -- "$ARTIFACT_DIR"/kittymgr-*-"$SUFFIX".tar.gz
    [ -e "$1" ] || fail "no kittymgr-*-$SUFFIX.tar.gz found in $ARTIFACT_DIR"
    [ "$#" -eq 1 ] || fail "multiple versions in $ARTIFACT_DIR; pick one with --version"
    VERSION="${1##*/}"
    VERSION="${VERSION#kittymgr-}"
    VERSION="${VERSION%-$SUFFIX.tar.gz}"
  else
    require_tool curl
    VERSION="$(curl -fsSL --proto '=https' --tlsv1.2 \
        "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
      | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"v([^"]+)".*/\1/p' \
      | head -n 1)"
    [ -n "$VERSION" ] || fail "could not resolve the latest release of $REPO_SLUG"
  fi
fi

ASSET="kittymgr-$VERSION-$SUFFIX.tar.gz"
BASE_URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION"
BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/kittymgr"
if [ -n "$ARTIFACT_DIR" ]; then
  SOURCE_LABEL="$ARTIFACT_DIR/$ASSET"
else
  SOURCE_LABEL="$BASE_URL/$ASSET"
fi

echo "install.sh:"
echo "- platform: $PLATFORM_LABEL"
echo "- release:  v$VERSION"
echo "- source:   $SOURCE_LABEL"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "- checksum: would verify $ASSET against SHA256SUMS (mismatch aborts)"
  echo "- would install: $TARGET"
  echo "dry-run: nothing was downloaded or written"
  exit 0
fi

WORKDIR="$(mktemp -d)"
STAGED=""
cleanup() {
  rm -rf "$WORKDIR"
  if [ -n "$STAGED" ]; then
    rm -f "$STAGED"
  fi
}
trap cleanup EXIT

if [ -n "$ARTIFACT_DIR" ]; then
  [ -f "$ARTIFACT_DIR/$ASSET" ] || fail "$ARTIFACT_DIR/$ASSET not found"
  [ -f "$ARTIFACT_DIR/SHA256SUMS" ] || fail "$ARTIFACT_DIR/SHA256SUMS not found"
  cp "$ARTIFACT_DIR/$ASSET" "$ARTIFACT_DIR/SHA256SUMS" "$WORKDIR/"
else
  require_tool curl
  curl -fSL --proto '=https' --tlsv1.2 --retry 2 \
    -o "$WORKDIR/$ASSET" "$BASE_URL/$ASSET" \
    || fail "download failed: $BASE_URL/$ASSET"
  curl -fSL --proto '=https' --tlsv1.2 --retry 2 \
    -o "$WORKDIR/SHA256SUMS" "$BASE_URL/SHA256SUMS" \
    || fail "download failed: $BASE_URL/SHA256SUMS"
fi

CHECKSUM_LINE="$(awk -v f="$ASSET" '$2 == f' "$WORKDIR/SHA256SUMS")"
[ -n "$CHECKSUM_LINE" ] || fail "SHA256SUMS does not list $ASSET"
if ! (cd "$WORKDIR" && printf '%s\n' "$CHECKSUM_LINE" | sha256_check); then
  fail "checksum mismatch for $ASSET — refusing to install"
fi
echo "- checksum: OK"

mkdir -p "$WORKDIR/extract"
tar -xzf "$WORKDIR/$ASSET" -C "$WORKDIR/extract"
SRC_BIN="$WORKDIR/extract/kittymgr-$VERSION-$SUFFIX/kittymgr"
[ -x "$SRC_BIN" ] || fail "binary not found inside $ASSET"
REPORTED="$("$SRC_BIN" --version)" \
  || fail "extracted binary failed to run on this host"
[ "$REPORTED" = "kittymgr $VERSION" ] \
  || fail "extracted binary reports '$REPORTED', expected 'kittymgr $VERSION'"

if [ -x "$TARGET" ] && [ "$(sha256_of "$TARGET")" = "$(sha256_of "$SRC_BIN")" ]; then
  echo "- installed: $TARGET (already up to date — nothing changed)"
  exit 0
fi

mkdir -p "$BIN_DIR" 2>/dev/null \
  || fail "cannot create $BIN_DIR; choose a writable --prefix (this script never uses sudo)"
[ -w "$BIN_DIR" ] \
  || fail "$BIN_DIR is not writable; choose a writable --prefix (this script never uses sudo)"

# Stage in the target directory, then rename: the swap is atomic and a failed
# copy can never leave a half-written kittymgr on PATH.
STAGED="$BIN_DIR/.kittymgr.tmp.$$"
cp "$SRC_BIN" "$STAGED"
chmod 0755 "$STAGED"
mv -f "$STAGED" "$TARGET"
STAGED=""

echo "- installed: $TARGET"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" ;;
esac

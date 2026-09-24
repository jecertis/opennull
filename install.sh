#!/bin/sh
# opennull installer: downloads the latest release binary for your platform
# into ~/.local/bin (override with OPENNULL_INSTALL_DIR).
#
#   curl -fsSL https://raw.githubusercontent.com/jecertis/opennull/main/install.sh | sh
set -eu

REPO="jecertis/opennull"
INSTALL_DIR="${OPENNULL_INSTALL_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*" >&2; }
fail() { say "error: $*"; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

OS=$(uname -s)
ARCH=$(uname -m)
case "$OS" in
    Darwin) TARGET_TAIL=macos ;;
    Linux) TARGET_TAIL=linux ;;
    *) fail "unsupported OS: $OS" ;;
esac
case "$ARCH" in
    x86_64|amd64) TARGET="x86_64-$TARGET_TAIL" ;;
    arm64|aarch64) TARGET="aarch64-$TARGET_TAIL" ;;
    *) fail "unsupported architecture: $ARCH" ;;
esac

say "==> resolving latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p') ||
    fail "could not reach GitHub"
[ -n "$TAG" ] || fail "no releases found"

ASSET="opennull-$TAG-$TARGET.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT

say "==> downloading $ASSET"
curl -fSL --progress-bar -o "$TMPDIR_DL/$ASSET" "$URL" ||
    fail "download failed ($URL)"

# Verify against the release's SHA256SUMS when it publishes one (releases
# before v0.1.3 don't; those install with a warning).
if curl -fsSL -o "$TMPDIR_DL/SHA256SUMS" "https://github.com/$REPO/releases/download/$TAG/SHA256SUMS" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL=$(sha256sum "$TMPDIR_DL/$ASSET" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL=$(shasum -a 256 "$TMPDIR_DL/$ASSET" | cut -d' ' -f1)
    else
        fail "need sha256sum or shasum to verify the download"
    fi
    EXPECTED=$(awk -v f="$ASSET" '$2 == f || $2 == "*" f { print $1 }' "$TMPDIR_DL/SHA256SUMS")
    [ -n "$EXPECTED" ] || fail "SHA256SUMS has no entry for $ASSET"
    [ "$EXPECTED" = "$ACTUAL" ] || fail "checksum mismatch for $ASSET; not installing"
    say "==> checksum verified"
else
    say "warning: release $TAG has no SHA256SUMS; download integrity not verified"
fi

say "==> extracting"
tar -xzf "$TMPDIR_DL/$ASSET" -C "$TMPDIR_DL"

mkdir -p "$INSTALL_DIR"
mv "$TMPDIR_DL/opennull-$TAG-$TARGET/opennull" "$INSTALL_DIR/opennull"
chmod +x "$INSTALL_DIR/opennull"

say "==> installed $INSTALL_DIR/opennull ($TAG, $TARGET)"

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        say ""
        say "NOTE: $INSTALL_DIR is not on your PATH. Add this to your shell profile:"
        say "      export PATH=\"$INSTALL_DIR:\$PATH\""
        ;;
esac

"$INSTALL_DIR/opennull" 2>/dev/null | head -1 || true

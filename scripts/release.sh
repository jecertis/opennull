#!/bin/sh
# Builds the release tarballs for every supported platform plus SHA256SUMS
# into dist/, in the layout install.sh and `opennull upgrade` expect:
#   opennull-vX.Y.Z-<target>.tar.gz -> opennull-vX.Y.Z-<target>/{opennull,LICENSE,README.md}
# Publishing stays manual; the script prints the gh command to run.
#
#   scripts/release.sh
set -eu

cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' src/root.zig)
[ -n "$VERSION" ] || { echo "error: could not read version from src/root.zig" >&2; exit 1; }
TAG="v$VERSION"

# release name  zig target (Linux builds are fully static via musl)
TARGETS="x86_64-linux:x86_64-linux-musl
aarch64-linux:aarch64-linux-musl
x86_64-macos:x86_64-macos
aarch64-macos:aarch64-macos"

if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

rm -rf dist
mkdir -p dist
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "$TARGETS" | while IFS=: read -r name triple; do
    stage="opennull-$TAG-$name"
    echo "==> $stage ($triple)"
    zig build -Dtarget="$triple" -Doptimize=ReleaseSafe -Dstrip=true -p "$WORK/$name"
    mkdir -p "$WORK/pkg/$stage"
    cp "$WORK/$name/bin/opennull" LICENSE README.md "$WORK/pkg/$stage/"
    chmod 755 "$WORK/pkg/$stage/opennull"
    tar -czf "dist/$stage.tar.gz" -C "$WORK/pkg" "$stage"
done

(cd dist && $SHA opennull-*.tar.gz > SHA256SUMS)
echo "==> dist/"
ls -l dist
echo
echo "Publish with:"
echo "  gh release create $TAG dist/*.tar.gz dist/SHA256SUMS --title $TAG"

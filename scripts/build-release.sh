#!/bin/sh
# Build the release archive: dist/scwrote-macos.tar.gz and its .sha256.
#
#   scripts/build-release.sh <version>     version is X.Y.Z, or 0.0.0-dev
#
# The archive holds a universal (arm64 + x86_64), ad-hoc signed binary, its
# resource bundles, the launcher, VERSION, LICENSE and THIRD_PARTY_LICENSES
# (at the top level, and again under share/scwrote/ so installs carry them).
set -eu

usage() {
  echo "usage: $0 <version>   (X.Y.Z or 0.0.0-dev)" >&2
  exit 2
}

[ $# -eq 1 ] || usage
version="$1"
case "$version" in
  0.0.0-dev) ;;
  *[!0-9.]* | .* | *. | *..* | "") usage ;;
  *.*.*.*) usage ;;
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) usage ;;
esac

cd "$(dirname "$0")/.."
root="$(pwd)"

# The preview's renderer page, which the app bundles as a resource.
(cd web && bun install --frozen-lockfile && bun test && bun run build)

swift test

# One build per architecture with SwiftPM's native build system, joined with
# lipo. A single build with both --arch flags goes through the other build
# system (swiftbuild, also the default in newer Swift), which with Xcode 26
# can't link libghostty's static library ("library not found for -lghostty").
# The resource bundles are the same for both, so they come from the arm64 one.
build_slice() {
  swift build -c release --build-system native --triple "$1-apple-macosx26.0" >&2 || exit 1
  swift build -c release --build-system native --triple "$1-apple-macosx26.0" --show-bin-path
}
products="$(build_slice arm64)"
intel="$(build_slice x86_64)"
universal="$root/.build/universal"
rm -rf "$universal"
mkdir -p "$universal"
binary="$universal/Scwrote"
lipo -create "$products/Scwrote" "$intel/Scwrote" -output "$binary"

# Ad-hoc sign the binary only, then make sure it is universal and valid.
codesign --force --sign - "$binary"
codesign --verify --strict "$binary"
archs="$(lipo -archs "$binary")"
for a in arm64 x86_64; do
  case " $archs " in
    *" $a "*) ;;
    *) echo "error: $binary is missing the $a slice (has: $archs)" >&2; exit 1 ;;
  esac
done

dist="$root/dist"
stage="$dist/stage/scwrote"
rm -rf "$dist/stage" "$dist/scwrote-macos.tar.gz" "$dist/scwrote-macos.tar.gz.sha256"
mkdir -p "$stage/bin" "$stage/share/scwrote"
cp bin/scwrote "$stage/bin/scwrote"
chmod +x "$stage/bin/scwrote"
cp "$binary" "$stage/share/scwrote/"
cp -R "$products"/*.bundle "$stage/share/scwrote/"
printf '%s\n' "$version" > "$stage/share/scwrote/VERSION"
cp LICENSE THIRD_PARTY_LICENSES "$stage/"
cp LICENSE THIRD_PARTY_LICENSES "$stage/share/scwrote/"

tar -czf "$dist/scwrote-macos.tar.gz" -C "$dist/stage" scwrote
(cd "$dist" && shasum -a 256 scwrote-macos.tar.gz > scwrote-macos.tar.gz.sha256)
rm -rf "$dist/stage"

echo "Built $dist/scwrote-macos.tar.gz ($version)"

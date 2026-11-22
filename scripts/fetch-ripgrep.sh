#!/bin/sh
# Fetch the pinned ripgrep into .build/ripgrep/rg: one universal (arm64 +
# x86_64), ad-hoc signed binary.
#
#   sh scripts/fetch-ripgrep.sh
#
# scwrote's project search runs rg. Release builds ship this binary as
# share/scwrote/rg; `swift run` and the tests find it in .build/ripgrep/. It
# does nothing when the right version is already there.
#
# ripgrep publishes one macOS archive per architecture and no universal one, so
# the two are joined with lipo. The version and both SHA-256 sums are pinned
# here, not fetched from the release, so a changed or swapped archive fails the
# check instead of being shipped.
set -eu

version="15.2.0"
arm_archive="ripgrep-$version-aarch64-apple-darwin.tar.gz"
arm_sha256="3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"
intel_archive="ripgrep-$version-x86_64-apple-darwin.tar.gz"
intel_sha256="af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1"
base_url="https://github.com/BurntSushi/ripgrep/releases/download/$version"

cd "$(dirname "$0")/.."
out=".build/ripgrep/rg"

# Both halves must be there: a binary built for one architecture only would
# fail on the other kind of Mac.
require_universal() {
  archs="$(lipo -archs "$1")"
  for a in arm64 x86_64; do
    case " $archs " in
      *" $a "*) ;;
      *) echo "error: $1 is missing the $a slice (has: $archs)" >&2; exit 1 ;;
    esac
  done
}

# The first line of --version is "ripgrep 15.2.0 (rev <hash>)".
has_version() {
  case "$("$1" --version 2>/dev/null | head -n 1)" in
    "ripgrep $version" | "ripgrep $version "*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -x "$out" ] && has_version "$out" && (require_universal "$out") 2>/dev/null; then
  echo "ripgrep $version already at $out"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
  curl -fsSL "$base_url/$1" -o "$work/$1"
  if ! (cd "$work" && printf '%s  %s\n' "$2" "$1" | shasum -a 256 -c - >/dev/null 2>&1); then
    echo "error: checksum mismatch for $1" >&2
    exit 1
  fi
  tar -xzf "$work/$1" -C "$work"
}
fetch "$arm_archive" "$arm_sha256"
fetch "$intel_archive" "$intel_sha256"

mkdir -p "$(dirname "$out")"
rm -f "$out"
lipo -create \
  "$work/${arm_archive%.tar.gz}/rg" "$work/${intel_archive%.tar.gz}/rg" \
  -output "$out"

# lipo's output is unsigned, which arm64 macOS refuses to run.
codesign --force --sign - "$out"
codesign --verify --strict "$out"
require_universal "$out"
if ! has_version "$out"; then
  echo "error: $out does not report ripgrep $version" >&2
  exit 1
fi

echo "Fetched ripgrep $version to $out"

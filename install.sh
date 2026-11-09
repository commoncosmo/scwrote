#!/bin/sh
# Test, build, and install scwrote under ~/.local (override with PREFIX=...):
#
#   $PREFIX/bin/scwrote              the command you type
#   $PREFIX/share/scwrote/Scwrote    the app binary
#   $PREFIX/share/scwrote/*.bundle   resources the binary loads from beside itself
#
# The installed copy doesn't depend on this repo or its .build folder.
set -eu
cd "$(dirname "$0")"

prefix="${PREFIX:-$HOME/.local}"
bindir="$prefix/bin"
appdir="$prefix/share/scwrote"

swift test
swift build -c release

# Assemble the new copy beside the old one, then swap it in. Writing fresh
# files (instead of overwriting in place) also keeps macOS from killing the
# binary over a stale cached code signature.
mkdir -p "$bindir" "$prefix/share"
rm -rf "$appdir.new"
mkdir "$appdir.new"
cp .build/release/Scwrote "$appdir.new/"
cp -R .build/release/*.bundle "$appdir.new/"
rm -rf "$appdir"
mv "$appdir.new" "$appdir"

# Replace whatever is there, including a symlink into this repo.
rm -f "$bindir/scwrote"
cp bin/scwrote "$bindir/scwrote"
chmod +x "$bindir/scwrote"

echo "Installed: $bindir/scwrote -> $appdir/Scwrote"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "Note: $bindir is not on your PATH." ;;
esac

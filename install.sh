#!/bin/sh
# Install scwrote from a prebuilt release (macOS 26 or later):
#
#   curl -fsSL https://raw.githubusercontent.com/commoncosmo/scwrote/main/install.sh | sh
#
# Installs under ~/.local, with no sudo:
#
#   $PREFIX/bin/scwrote              the command you type
#   $PREFIX/share/scwrote/Scwrote    the app binary
#   $PREFIX/share/scwrote/*.bundle   resources the binary loads from beside itself
#   $PREFIX/share/scwrote/VERSION    the installed version
#
# Environment variables:
#
#   PREFIX               where to install (default: $HOME/.local)
#   SCWROTE_VERSION      a release to install, as X.Y.Z with no "v" (default: the latest)
#   SCWROTE_ARCHIVE      path to a local scwrote-macos.tar.gz to install instead of
#                        downloading (no checksum check)
#   SCWROTE_RELEASES_URL where releases are downloaded from
#                        (default: https://github.com/commoncosmo/scwrote/releases)
#
# If anything fails, the previous install is left as it was.
set -eu

die() {
  echo "scwrote install: $*" >&2
  exit 1
}

prefix="${PREFIX:-$HOME/.local}"
bindir="$prefix/bin"
appdir="$prefix/share/scwrote"
releases="${SCWROTE_RELEASES_URL:-https://github.com/commoncosmo/scwrote/releases}"
asset="scwrote-macos.tar.gz"

[ "$(uname -s)" = "Darwin" ] || die "scwrote runs on macOS only."
macos="$(sw_vers -productVersion)"
case "${macos%%.*}" in
  '' | *[!0-9]*) die "could not tell which macOS this is (sw_vers said '$macos')." ;;
esac
[ "${macos%%.*}" -ge 26 ] || die "scwrote needs macOS 26 or later (this is macOS $macos)."

work="$(mktemp -d "${TMPDIR:-/tmp}/scwrote-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

if [ -n "${SCWROTE_ARCHIVE:-}" ]; then
  [ -f "$SCWROTE_ARCHIVE" ] || die "no archive at $SCWROTE_ARCHIVE."
  archive="$SCWROTE_ARCHIVE"
else
  if [ -n "${SCWROTE_VERSION:-}" ]; then
    base="$releases/download/v$SCWROTE_VERSION"
    what="scwrote $SCWROTE_VERSION"
  else
    base="$releases/latest/download"
    what="the latest scwrote release"
  fi
  echo "Downloading $what..."
  archive="$work/$asset"
  curl -fsSL "$base/$asset" -o "$archive" ||
    die "could not download $what from $base/$asset (is that release published?)."
  curl -fsSL "$base/$asset.sha256" -o "$work/$asset.sha256" ||
    die "could not download the checksum for $what."
  (cd "$work" && shasum -a 256 -c "$asset.sha256" >/dev/null 2>&1) ||
    die "checksum mismatch for $what; nothing was installed."
fi

mkdir "$work/unpacked"
tar -xzf "$archive" -C "$work/unpacked" 2>/dev/null ||
  die "$archive is not a scwrote release archive; nothing was installed."
src="$work/unpacked/scwrote"
[ -f "$src/share/scwrote/Scwrote" ] && [ -f "$src/bin/scwrote" ] ||
  die "the archive is missing scwrote/share/scwrote/Scwrote or scwrote/bin/scwrote; nothing was installed."

version=unknown
[ -f "$src/share/scwrote/VERSION" ] && version="$(cat "$src/share/scwrote/VERSION")"

previous=""
if [ -f "$appdir/VERSION" ]; then
  previous="$(cat "$appdir/VERSION")"
elif [ -e "$appdir" ] || [ -e "$bindir/scwrote" ]; then
  previous="an earlier version"
fi

# Assemble the new copy beside the old one, then swap it in. Writing fresh
# files (instead of overwriting in place) also keeps macOS from killing the
# binary over a stale cached code signature.
mkdir -p "$bindir" "$prefix/share"
rm -rf "$appdir.new"
cp -R "$src/share/scwrote" "$appdir.new" || {
  rm -rf "$appdir.new"
  die "could not write under $prefix; the previous install is unchanged."
}
chmod +x "$appdir.new/Scwrote"
rm -rf "$appdir"
mv "$appdir.new" "$appdir"

# Replace whatever is there, including a symlink into a repo.
rm -f "$bindir/scwrote"
cp "$src/bin/scwrote" "$bindir/scwrote"
chmod +x "$bindir/scwrote"

if [ -n "$previous" ]; then
  echo "Installed scwrote $version, replacing $previous: $bindir/scwrote"
else
  echo "Installed scwrote $version: $bindir/scwrote"
fi
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "Note: $bindir is not on your PATH. Add it to your shell profile to run scwrote." ;;
esac
command -v nvim >/dev/null 2>&1 ||
  echo "Note: scwrote needs Neovim: brew install neovim"

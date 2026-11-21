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

# Everything below runs inside main, called on the last line, so a download
# cut short (curl ... | sh) defines half a function and runs nothing.

die() {
  echo "scwrote install: $*" >&2
  exit 1
}

# fetch <url> <file>: https only, TLS 1.2+, when the URL is https.
fetch() {
  case "$1" in
    https://*) curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$2" ;;
    *) curl -fsSL "$1" -o "$2" ;;
  esac
}

# Runs on any exit. If the swap began but didn't finish, put the old install
# back (with renames only, so there is never a moment with no copy); always
# remove leftovers. Signals are ignored meanwhile so a second Ctrl-C can't
# interrupt it.
cleanup() {
  trap '' HUP INT TERM
  if [ -n "$appdir" ]; then
    # Once the launcher has been renamed into place, the swap is complete.
    if [ "$swap_started" = 1 ] && [ ! -e "$bindir/scwrote.new" ]; then
      swap_done=1
    fi
    if [ "$swap_started" = 1 ] && [ "$swap_done" != 1 ] && [ -d "$appdir.old" ]; then
      rm -rf "$appdir.new"
      if [ -e "$appdir" ]; then
        mv "$appdir" "$appdir.new"
      fi
      mv "$appdir.old" "$appdir"
    fi
    rm -rf "$appdir.new" "$bindir/scwrote.new"
    if [ "$swap_done" = 1 ]; then
      rm -rf "$appdir.old"
    fi
  fi
  if [ -n "$work" ]; then
    rm -rf "$work"
  fi
}

main() {
  appdir=""
  work=""
  swap_started=""
  swap_done=""
  prefix="${PREFIX:-$HOME/.local}"
  bindir="$prefix/bin"
  releases="${SCWROTE_RELEASES_URL:-https://github.com/commoncosmo/scwrote/releases}"
  asset="scwrote-macos.tar.gz"

  [ "$(uname -s)" = "Darwin" ] || die "scwrote runs on macOS only."
  macos="$(sw_vers -productVersion 2>/dev/null)" ||
    die "could not tell which macOS this is (sw_vers failed); scwrote needs macOS 26 or later."
  case "${macos%%.*}" in
    '' | *[!0-9]*) die "could not tell which macOS this is (sw_vers said '$macos'); scwrote needs macOS 26 or later." ;;
  esac
  [ "${macos%%.*}" -ge 26 ] || die "scwrote needs macOS 26 or later (this is macOS $macos)."

  appdir="$prefix/share/scwrote"
  # An update killed between its two renames leaves the old install as .old.
  if [ ! -e "$appdir" ] && [ -d "$appdir.old" ]; then
    echo "Restoring the previous install left by an interrupted update."
    mv "$appdir.old" "$appdir" || die "could not restore $appdir.old."
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/scwrote-install.XXXXXX")"
  trap cleanup EXIT
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
    fetch "$base/$asset" "$archive" ||
      die "could not download $what from $base/$asset (is that release published?)."
    fetch "$base/$asset.sha256" "$work/$asset.sha256" ||
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
  elif [ -e "$appdir" ] || [ -e "$bindir/scwrote" ] || [ -L "$bindir/scwrote" ]; then
    previous="an earlier version"
  fi

  # Assemble the new copy beside the old one, then swap it in with renames, so
  # there is never a moment with no install. Writing fresh files (instead of
  # overwriting in place) also keeps macOS from killing the binary over a stale
  # cached code signature.
  mkdir -p "$bindir" "$prefix/share" ||
    die "could not create $prefix; the previous install is unchanged."
  rm -rf "$appdir.new" "$bindir/scwrote.new"
  if [ -e "$appdir" ]; then
    rm -rf "$appdir.old"
  fi
  if ! { cp -R "$src/share/scwrote" "$appdir.new" &&
    chmod +x "$appdir.new/Scwrote" &&
    cp "$src/bin/scwrote" "$bindir/scwrote.new" &&
    chmod +x "$bindir/scwrote.new"; }; then
    die "could not write under $prefix; the previous install is unchanged."
  fi

  swap_started=1
  if [ -e "$appdir" ]; then
    mv "$appdir" "$appdir.old" || die "could not replace $appdir; the previous install is unchanged."
  fi
  mv "$appdir.new" "$appdir" || die "could not replace $appdir; the previous install is unchanged."
  # A rename replaces whatever is there atomically, including a symlink into a repo.
  mv -f "$bindir/scwrote.new" "$bindir/scwrote" ||
    die "could not replace $bindir/scwrote; the previous install is unchanged."
  swap_done=1
  rm -rf "$appdir.old"

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
}

main "$@"

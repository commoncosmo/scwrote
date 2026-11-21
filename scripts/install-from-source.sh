#!/bin/sh
# Build scwrote from this checkout and install it (PREFIX defaults to ~/.local):
#
#   scripts/install-from-source.sh
#
# Runs the tests, builds the release archive as version 0.0.0-dev, and installs
# that archive with install.sh.
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"

"$repo/scripts/build-release.sh" 0.0.0-dev
SCWROTE_ARCHIVE="$repo/dist/scwrote-macos.tar.gz" sh "$repo/install.sh"

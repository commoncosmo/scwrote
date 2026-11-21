#!/bin/sh
# Tests for install.sh and the launcher's --version. Run: sh scripts/tests/install-test.sh
#
# Every test installs into a temporary PREFIX from a fake release folder laid
# out like GitHub's, so nothing touches the real ~/.local and nothing launches.
set -u

repo="$(cd "$(dirname "$0")/../.." && pwd)"
root="$(mktemp -d "${TMPDIR:-/tmp}/scwrote-install-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT INT TERM

passed=0
failed=0
out=""
status=0

# --- fixtures ---------------------------------------------------------------

# make_archive <dir> <version> [--no-app]: <dir>/scwrote-macos.tar.gz + .sha256.
# The launcher is the repo's real one; the app binary is a harmless script.
make_archive() {
  _dir="$1"
  _ver="$2"
  _stage="$root/stage.$$.$_ver"
  rm -rf "$_stage"
  mkdir -p "$_stage/scwrote/bin" "$_stage/scwrote/share/scwrote/Fake.bundle" "$_dir"
  cp "$repo/bin/scwrote" "$_stage/scwrote/bin/scwrote"
  chmod +x "$_stage/scwrote/bin/scwrote"
  if [ "${3:-}" != "--no-app" ]; then
    printf '#!/bin/sh\necho fake app >&2\n' > "$_stage/scwrote/share/scwrote/Scwrote"
    chmod +x "$_stage/scwrote/share/scwrote/Scwrote"
  fi
  : > "$_stage/scwrote/share/scwrote/Fake.bundle/res"
  printf '%s\n' "$_ver" > "$_stage/scwrote/share/scwrote/VERSION"
  echo license > "$_stage/scwrote/LICENSE"
  tar -czf "$_dir/scwrote-macos.tar.gz" -C "$_stage" scwrote
  (cd "$_dir" && shasum -a 256 scwrote-macos.tar.gz > scwrote-macos.tar.gz.sha256)
  rm -rf "$_stage"
}

# setup: a fresh temp world for one test, with releases 1.0.0 and 1.2.3 (latest).
setup() {
  T="$root/t.$1"
  rm -rf "$T"
  mkdir -p "$T/home" "$T/tmp" "$T/shim"
  PREFIX="$T/prefix"
  REL="$T/releases"
  make_archive "$REL/latest/download" 1.2.3
  make_archive "$REL/download/v1.2.3" 1.2.3
  make_archive "$REL/download/v1.0.0" 1.0.0
  printf '#!/bin/sh\necho 26.0\n' > "$T/shim/sw_vers"
  chmod +x "$T/shim/sw_vers"
  SHIM="$T/shim"
  EXTRA_PATH=""
}

# run_install [VAR=value ...]: run install.sh from a file, capturing out/status.
# PATH is just the shim plus system tools, so nvim is absent unless EXTRA_PATH adds it.
run_install() {
  out="$(env -i HOME="$T/home" TMPDIR="$T/tmp" PREFIX="$PREFIX" \
    PATH="$SHIM:${EXTRA_PATH:+$EXTRA_PATH:}/usr/bin:/bin" \
    SCWROTE_RELEASES_URL="file://$REL" "$@" sh "$repo/install.sh" 2>&1 </dev/null)"
  status=$?
}

snapshot() {
  (cd "$1" 2>/dev/null && find . | sort && find . -type f -exec cksum {} + | sort)
}

assert_status_ok() { [ "$status" -eq 0 ] || { echo "  expected exit 0, got $status: $out"; return 1; }; }
assert_status_fail() { [ "$status" -ne 0 ] || { echo "  expected nonzero exit: $out"; return 1; }; }
assert_contains() {
  case "$out" in
    *"$1"*) ;;
    *) echo "  expected output to contain '$1', got: $out"; return 1 ;;
  esac
}
assert_not_contains() {
  case "$out" in
    *"$1"*) echo "  expected output not to contain '$1', got: $out"; return 1 ;;
  esac
}
assert_version() {
  _got="$("$PREFIX/bin/scwrote" --version 2>&1)"
  [ "$_got" = "scwrote $1" ] || { echo "  expected 'scwrote $1', got '$_got'"; return 1; }
}

# --- tests ------------------------------------------------------------------

test_installs_latest() {
  run_install
  assert_status_ok || return 1
  [ -x "$PREFIX/bin/scwrote" ] || { echo "  no launcher"; return 1; }
  [ -x "$PREFIX/share/scwrote/Scwrote" ] || { echo "  no app"; return 1; }
  assert_version 1.2.3
}

test_installs_named_version() {
  run_install SCWROTE_VERSION=1.0.0
  assert_status_ok || return 1
  assert_version 1.0.0
}

test_checksum_mismatch_changes_nothing() {
  run_install SCWROTE_VERSION=1.0.0 || return 1
  before="$(snapshot "$PREFIX")"
  echo tampered >> "$REL/latest/download/scwrote-macos.tar.gz"
  run_install
  assert_status_fail || return 1
  assert_contains checksum || return 1
  [ "$before" = "$(snapshot "$PREFIX")" ] || { echo "  install changed"; return 1; }
}

test_missing_release_changes_nothing() {
  run_install SCWROTE_VERSION=1.0.0 || return 1
  before="$(snapshot "$PREFIX")"
  run_install SCWROTE_VERSION=9.9.9
  assert_status_fail || return 1
  assert_contains 9.9.9 || return 1
  [ "$before" = "$(snapshot "$PREFIX")" ] || { echo "  install changed"; return 1; }
}

test_broken_archive_keeps_old_install() {
  run_install SCWROTE_VERSION=1.0.0 || return 1
  before="$(snapshot "$PREFIX")"
  echo "not gzip" > "$T/bad.tar.gz"
  run_install SCWROTE_ARCHIVE="$T/bad.tar.gz"
  assert_status_fail || return 1
  [ "$before" = "$(snapshot "$PREFIX")" ] || { echo "  (a) install changed"; return 1; }
  make_archive "$T/noapp" 2.0.0 --no-app
  run_install SCWROTE_ARCHIVE="$T/noapp/scwrote-macos.tar.gz"
  assert_status_fail || return 1
  [ "$before" = "$(snapshot "$PREFIX")" ] || { echo "  (b) install changed"; return 1; }
  [ ! -e "$PREFIX/share/scwrote.new" ] || { echo "  scwrote.new left behind"; return 1; }
}

test_refuses_old_macos() {
  printf '#!/bin/sh\necho 15.6\n' > "$SHIM/sw_vers"
  run_install
  assert_status_fail || return 1
  assert_contains "macOS 26" || return 1
  [ ! -e "$PREFIX" ] || { echo "  wrote under PREFIX"; return 1; }
}

test_update_reports_previous_version() {
  run_install SCWROTE_VERSION=1.0.0 || return 1
  run_install
  assert_status_ok || return 1
  assert_contains 1.0.0 || return 1
  assert_contains 1.2.3
}

test_update_over_unversioned_install() {
  run_install || return 1
  rm "$PREFIX/share/scwrote/VERSION"
  run_install
  assert_status_ok || return 1
  assert_contains "an earlier version"
}

test_warns_without_nvim() {
  run_install
  assert_status_ok || return 1
  assert_contains "brew install neovim" || return 1
  mkdir "$T/nvimbin"
  printf '#!/bin/sh\n' > "$T/nvimbin/nvim"
  chmod +x "$T/nvimbin/nvim"
  EXTRA_PATH="$T/nvimbin"
  run_install
  assert_status_ok || return 1
  assert_not_contains "brew install neovim"
}

test_warns_when_bin_not_on_path() {
  run_install
  assert_status_ok || return 1
  assert_contains "not on your PATH" || return 1
  mkdir -p "$PREFIX/bin"
  EXTRA_PATH="$PREFIX/bin"
  run_install
  assert_not_contains "not on your PATH"
}

test_install_prefix_with_spaces() {
  PREFIX="$T/my tools"
  run_install
  assert_status_ok || return 1
  assert_version 1.2.3
}

test_runs_from_stdin() {
  out="$(env -i HOME="$T/home" TMPDIR="$T/tmp" PREFIX="$PREFIX" \
    PATH="$SHIM:/usr/bin:/bin" SCWROTE_ARCHIVE="$REL/latest/download/scwrote-macos.tar.gz" \
    sh < "$repo/install.sh" 2>&1)"
  status=$?
  assert_status_ok || return 1
  assert_version 1.2.3
}

test_launcher_version_without_version_file() {
  mkdir -p "$T/l/bin" "$T/l/share/scwrote"
  cp "$repo/bin/scwrote" "$T/l/bin/scwrote"
  printf '#!/bin/sh\ntouch "%s/launched"\n' "$T" > "$T/l/share/scwrote/Scwrote"
  chmod +x "$T/l/bin/scwrote" "$T/l/share/scwrote/Scwrote"
  out="$(env -i HOME="$T/home" PATH=/usr/bin:/bin "$T/l/bin/scwrote" --version 2>&1)"
  status=$?
  assert_status_ok || return 1
  [ "$out" = "scwrote 0.0.0-dev" ] || { echo "  got '$out'"; return 1; }
  sleep 1
  [ ! -e "$T/launched" ] || { echo "  launcher launched the app"; return 1; }
}

test_no_temp_left_behind() {
  run_install
  assert_status_ok || return 1
  run_install SCWROTE_VERSION=9.9.9
  assert_status_fail || return 1
  left="$(find "$T/tmp" -name 'scwrote-install.*' 2>/dev/null)"
  [ -z "$left" ] || { echo "  left behind: $left"; return 1; }
}

# --- runner -----------------------------------------------------------------

sed -n 's/^test_\([a-z_]*\)() {$/\1/p' "$0" > "$root/names"
while read -r t; do
  setup "$t"
  if result="$( (test_"$t") 2>&1 )"; then
    passed=$((passed + 1))
    echo "ok   $t"
  else
    failed=$((failed + 1))
    echo "FAIL $t"
    [ -z "$result" ] || echo "$result"
  fi
done < "$root/names"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

#!/bin/sh
# Launch the Scwrote binary on a temporary Markdown file and succeed once it
# has opened a window (it saves a snapshot of it). Fails after 60 seconds.
#
#   scripts/smoke-test.sh <path to Scwrote binary>
#
# The app needs nvim on PATH. Only the process started here, and the nvim it
# started, are stopped; any other running scwrote is left alone.
set -u

[ $# -eq 1 ] || { echo "usage: $0 <path to Scwrote binary>" >&2; exit 2; }
[ -x "$1" ] || { echo "smoke test failed: $1 is not an executable file" >&2; exit 1; }
binary=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")

dir=$(mktemp -d "${TMPDIR:-/tmp}/scwrote-smoke.XXXXXX") || exit 1
app=""

# The pid of $1 and of everything below it.
tree() {
  echo "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do tree "$child"; done
}

cleanup() {
  if [ -n "$app" ]; then
    pids=$(tree "$app")
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null
    sleep 1
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null
    wait "$app" 2>/dev/null
  fi
  rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

printf '# smoke\n' > "$dir/note.md"
cd "$dir" || exit 1
SCWROTE_DEBUG_SNAPSHOT="$dir/snap.png" "$binary" note.md > "$dir/app.log" 2>&1 &
app=$!

waited=0
while [ "$waited" -lt 60 ]; do
  if [ -s "$dir/snap.png" ]; then
    echo "smoke test passed"
    exit 0
  fi
  if ! kill -0 "$app" 2>/dev/null; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "smoke test failed: no window snapshot after ${waited}s; the app's log:" >&2
cat "$dir/app.log" >&2
exit 1

#!/bin/sh
# The PerfLoop loop on SlowList, end to end: build the champion and two candidates, store, champion, a knob experiment,
# a deliberate cheat the guards must refuse, a real code fix screened, run in full, promoted, and the ledger.
#
#   ./walkthrough.sh --dry-run          print every command, run nothing (no window)
#   ./walkthrough.sh [--lock DIR]       run it: builds for ~5 min, then opens a window 34 times over ~2 min, so run it when nobody is using the
#                                       Mac (or on a spare one). --lock DIR takes turns with other benches on this Mac.
#   ./walkthrough.sh --keep             keep the scratch store and binaries (default: deleted at the end)
#   ./walkthrough.sh --reuse            with PERFLOOP_WALK set: reuse the benches a kept run built (the store starts anew)
#
# Everything goes to a scratch directory ($PERFLOOP_WALK, default a new mktemp -d): the store, the three bench
# builds. Nothing is written inside the repo. Builds are stamped from this checkout: commit first, or promotion refuses
# the dirty build (the script says so).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
pkg=$(cd "$here/../.." && pwd)
dry=0; keep=0; lock=""; reuse=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;; --keep) keep=1; shift ;; --reuse) reuse=1; shift ;; --lock) lock=$2; shift 2 ;;
    *) echo "usage: $0 [--dry-run] [--lock DIR] [--keep] [--reuse]" >&2; exit 1 ;;
  esac
done
W=${PERFLOOP_WALK:-$( [ $dry = 1 ] && echo /tmp/perfloop-walk || mktemp -d -t perfloop-walk)}
export PERFLOOP_HOME="$W/home" PERFLOOP_APP=slowlist
P="$pkg/.build/release/perfloop"
runner="--runner local"; [ -n "$lock" ] && runner="$runner --lock $lock"

say() { printf '\n## %s\n' "$*"; }
run() {
  line='$'; for a in "$@"; do case "$a" in *[!A-Za-z0-9_./=:,@+-]*) line="$line '$a'" ;; *) line="$line $a" ;; esac; done
  echo "$line"; [ $dry = 1 ] || "$@"
}
# `exp new` prints the experiment; its id is what the next commands take.
new_exp() {
  if [ $dry = 1 ]; then run "$P" exp new "$@"; id=ID; return; fi
  out=$(run "$P" exp new "$@" --json); echo "$out" | sed -n '1p;/"state"/p'
  id=$(echo "$out" | sed -n 's/^  "id" : "\([0-9]*\)".*/\1/p' | head -1)
  [ -n "$id" ] || { echo "no experiment id in: $out" >&2; exit 2; }
}
cleanup() { if [ $keep = 0 ] && [ $dry = 0 ]; then rm -rf "$W"; echo "(removed $W)"; else echo "(kept $W)"; fi; }
trap cleanup EXIT

say "build the runner and three benches: the app as it is (the champion), a code fix, a cheat"
run swift build -c release --package-path "$pkg" --product perfloop
[ $dry = 0 ] && rm -rf "$PERFLOOP_HOME"
for v in champion fix cheat; do
  if [ $reuse = 1 ] && [ -x "$W/bench-$v/SlowListBench" ]; then echo "(reusing $W/bench-$v)"; continue; fi
  case $v in champion) flags="" ;; fix) flags="-Xswiftc -DSLOWLIST_ROW_VALUES" ;; cheat) flags="-Xswiftc -DSLOWLIST_CHEAT" ;; esac
  # shellcheck disable=SC2086
  run swift build -c release --package-path "$here" --product SlowListBench --scratch-path "$W/build-$v" $flags
  run mkdir -p "$W/bench-$v"
  run cp "$W/build-$v/release/SlowListBench" "$W/bench-$v/SlowListBench"
done
[ $dry = 1 ] || rm -rf "$W/build-champion" "$W/build-fix" "$W/build-cheat"

say "is this Mac and this bench ready?"
run "$P" doctor --bench "$W/bench-champion" || true

say "the champion: the app as it is"
run "$P" store add "$W/bench-champion"
if [ $dry = 1 ]; then h=HASH; else h=$("$P" store list --json | sed -n 's/.*"hash" : "sha256:\([0-9a-f]*\)".*/\1/p' | head -1); fi
run "$P" champion set "$h" --merged --scenario select --fixture rows1000 --note "SlowList as it is"

say "1. a knob: one binary, two ideas, no rebuild"
new_exp "rows look their rank up in a table built once instead of sorting the list" --knobs rows.rank=index --no-screen
run "$P" exp screen "$id" $runner
run "$P" explain "exp/$id"

say "2. a cheat: blank rows are fast; the guards must refuse it"
new_exp "rows draw nothing (a deliberate cheat)" --bench "$W/bench-cheat" --no-screen
run "$P" exp screen "$id" $runner || true
run "$P" explain "exp/$id"

say "3. a code fix: rows take values, so a selection re-evaluates two rows, and ranks come from one sort"
new_exp "rows take values: two bodies per selection, ranks sorted once" --bench "$W/bench-fix" --no-screen
run "$P" exp screen "$id" $runner
run "$P" exp full "$id" $runner
run "$P" exp promote "$id" || true
run "$P" explain "exp/$id"

say "what the loop remembers"
run "$P" exp status
run "$P" ledger
run "$P" champion

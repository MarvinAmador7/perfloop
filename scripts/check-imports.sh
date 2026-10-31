#!/bin/sh
# The genericity gate (design/perf-loop/SPEC.md §2.2): nothing under tools/perfloop/Sources may import a capcomd
# module (Capcomd*, or the bench's DeskBenchKit). Usage: check-imports.sh [SOURCES_DIR]; exit 1 with the offending
# lines when one does.
dir=${1:-"$(cd "$(dirname "$0")/.." && pwd)/Sources"}
hits=$(grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?(@_exported[[:space:]]+)?import[[:space:]]+(class |struct |enum |func |protocol )?(Capcomd[A-Za-z0-9_]*|DeskBenchKit)\b' "$dir" --include='*.swift' 2>/dev/null)
if [ -n "$hits" ]; then
  echo "perfloop: capcomd imports under $dir (the package must stay generic):" >&2
  echo "$hits" >&2
  exit 1
fi
echo "perfloop: no capcomd imports under $dir"

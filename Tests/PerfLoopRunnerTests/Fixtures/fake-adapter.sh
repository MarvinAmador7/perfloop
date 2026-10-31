#!/bin/sh
# perfloop's fake adapter: deskbench-shaped output for list, describe, ab, run and diff, with no window and no app.
# Tests copy this file and edit the FAKE_ lines below: each copy is one "build" (its own sha256). `ab` reads the
# FAKE_ lines of the two binaries it is given, as deskbench's `ab` runs them.
FAKE_CPU=40
FAKE_HITCH=3
FAKE_HZ=120
FAKE_LATE=2
FAKE_CHECK_FAIL=
FAKE_STAMP=1
FAKE_COMMIT=abc1234
FAKE_DIRTY=false
FAKE_DESCRIBE=1
FAKE_NOISE=0.02
FAKE_SWARM=1
FAKE_CLIP_DIV=1
FAKE_AB_FAIL=0

self="$0"
log() { if [ -n "$FAKE_LOG" ]; then echo "$*" >> "$FAKE_LOG"; fi; }
val() { grep "^$2=" "$1" | head -1 | cut -d= -f2; }
sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
jitter() { awk -v v="$1" -v n="$2" -v s="$3" 'BEGIN { srand(s); printf "%.3f", v * (1 + (rand() * 2 - 1) * n) }'; }
build() { echo "{\"commit\": \"$(val "$1" FAKE_COMMIT)\", \"dirty\": $(val "$1" FAKE_DIRTY), \"configuration\": \"release\", \"stamp\": true, \"builtAt\": \"2026-10-30T20:00:00Z\", \"hash\": \"sha256:$(sha "$1")\"}"; }
checks() { f=$(val "$1" FAKE_CHECK_FAIL); if [ -n "$f" ]; then echo "\"$f\""; fi; }
cpu_of() {   # exe fixture knobs seed
  c=$(val "$1" FAKE_CPU)
  if [ "$2" = swarm64 ]; then c=$(awk -v c="$c" -v m="$(val "$1" FAKE_SWARM)" 'BEGIN { print c * m }'); fi
  case "$3" in *reel.slide=clip*) c=$(awk -v c="$c" -v d="$(val "$1" FAKE_CLIP_DIV)" 'BEGIN { print c / d }') ;; esac
  jitter "$c" "$(val "$1" FAKE_NOISE)" "$4"
}

cmd=$1; shift
case "$cmd" in
list)
  log "list $self"
  b=""; if [ "$FAKE_STAMP" = 1 ]; then b="\"build\": $(build "$self"),"; fi
  cat <<JSON
{ "tool": { $b "name": "FakeBench", "version": "1", "configuration": "release" },
  "scenarios": [ { "name": "step", "kind": "smooth", "params": { "steps": "8" }, "summary": "s", "budget": "b", "rule": "r" },
                 { "name": "switch", "kind": "latency", "latencyBudgetMs": 50, "params": {}, "summary": "s", "budget": "b", "rule": "r" } ],
  "fixtures": [ { "name": "crew17" }, { "name": "swarm64" } ], "suite": ["step", "switch"], "exitCodes": { "ok": 0, "regression": 4 } }
JSON
  ;;
describe)
  if [ "$FAKE_DESCRIBE" != 1 ]; then echo "deskbench: unknown command 'describe'" >&2; exit 1; fi
  cat <<JSON
{ "schema": "perfloop.manifest/1", "protocol": 1, "app": "fake-app", "adapter": "fakebench",
  "scenarios": [ { "name": "step", "kind": "smooth", "params": { "steps": "8" }, "objective": "mainThreadCpuMsPerStep", "guards": ["landed"], "secondFixture": "swarm64" },
                 { "name": "switch", "kind": "latency", "objective": "latencyMs", "guards": ["checks"] } ],
  "fixtures": [ { "name": "crew17" }, { "name": "swarm64" } ],
  "knobs": [ { "name": "reel.slide", "type": "choice", "default": "ca", "choices": ["ca", "clip"] } ], "hosts": ["scene"] }
JSON
  ;;
ab)
  a=""; b=""; out=""; fixture=crew17; sc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --a) a=$2; shift 2 ;; --b) b=$2; shift 2 ;; --out) out=$2; shift 2 ;; --fixture) fixture=$2; shift 2 ;;
      --reps|--set|--objective) shift 2 ;; --*) shift ;; *) sc=$1; shift ;;
    esac
  done
  log "ab $sc $fixture A=$a B=$b"
  if [ "$(val "$b" FAKE_AB_FAIL)" = 1 ] || [ "$(val "$a" FAKE_AB_FAIL)" = 1 ]; then echo "ab: child crashed" >&2; exit 2; fi
  s=$$
  ca=$(cpu_of "$a" "$fixture" "" "$s"); cb=$(cpu_of "$b" "$fixture" "" "$((s + 7))")
  summ() { echo "{ \"reps\": 1, \"objective\": { \"name\": \"mainThreadCpuMsPerStep\", \"value\": $2 }, \"mainThreadCpuMsPerStep\": { \"n\": 1, \"median\": $2 },
    \"hitchTimeRatioMsPerS\": { \"median\": $(val "$1" FAKE_HITCH) }, \"longestStretchMs\": { \"median\": 40 }, \"steadyHz\": { \"median\": $(val "$1" FAKE_HZ) },
    \"lateFrames\": { \"median\": $(val "$1" FAKE_LATE) }, \"checksFailed\": [ $(checks "$1") ], \"aNewField\": { \"x\": 1 } }"; }
  json="{ \"schema\": \"deskbench.ab/1\", \"scenario\": \"$sc\", \"fixture\": \"$fixture\", \"a\": \"$a\", \"b\": \"$b\", \"repsPerSide\": 1,
  \"summaryA\": $(summ "$a" "$ca"), \"summaryB\": $(summ "$b" "$cb"), \"comparison\": [], \"failures\": [], \"regression\": false, \"improvement\": false,
  \"objective\": \"mainThreadCpuMsPerStep\", \"guardsFailed\": [], \"notes\": [], \"buildA\": $(build "$a"), \"buildB\": $(build "$b"), \"counterbalanced\": true }"
  if [ -n "$out" ]; then echo "$json" > "$out"; fi
  echo "$json"
  ;;
run)
  sc=$1; shift; fixture=crew17
  while [ $# -gt 0 ]; do case "$1" in --fixture) fixture=$2; shift 2 ;; --reps|--set|--quiet-check) shift 2 ;; *) shift ;; esac; done
  log "run $sc $fixture knobs=$PERFLOOP_KNOBS $self"
  c=$(cpu_of "$self" "$fixture" "$PERFLOOP_KNOBS" "$$")
  total=$(awk -v c="$c" 'BEGIN { printf "%.1f", c * 8 }')
  lat=$(awk -v c="$c" 'BEGIN { printf "%.2f", c * 3 }')
  step="{ \"name\": \"step\", \"atMs\": 0, \"durationMs\": 300, \"latencyMs\": $lat, \"frames\": { \"steadyHz\": 120 }, \"mainThread\": { \"cpuMs\": 1 }, \"bodies\": {}, \"notes\": [] }"
  fail=$(checks "$self"); landed=true; if [ "$fail" = '"landed"' ]; then landed=false; fi
  cat <<JSON
{ "schema": "deskbench.result/1", "tool": { "name": "FakeBench", "version": "1", "configuration": "release", "build": $(build "$self") },
  "scenario": "$sc", "fixture": "$fixture", "params": {}, "profiled": false,
  "reps": [ { "index": 0, "steps": [ $step, $step, $step, $step, $step, $step, $step, $step ],
              "frames": { "steadyHz": $FAKE_HZ, "late": $FAKE_LATE, "hitchTimeRatioMsPerS": $FAKE_HITCH },
              "mainThread": { "cpuMs": $total, "longestMs": 40 }, "bodies": {},
              "checks": [ { "name": "landed", "pass": $landed, "detail": "" } ],
              "window": { "appActive": true, "keyWindow": true, "visible": true, "occluded": false },
              "worstStretches": [ { "step": "step#3 9→12", "durationMs": 40, "cpuMs": 39, "bodies": {},
                                    "topOurs": [ { "symbol": "ReelView.slide", "samples": 30 } ],
                                    "topFramework": [ { "symbol": "LayoutEngineBox.sizeThatFits", "samples": 36, "under": "ReelRepresentable" } ] } ] } ],
  "summary": { "reps": 1 }, "verdict": "pass", "exitCode": 0 }
JSON
  ;;
diff)
  log "diff $1 $2"
  echo "{ \"schema\": \"deskbench.diff/1\", \"a\": \"$1\", \"b\": \"$2\", \"gains\": [], \"losses\": [] }"
  ;;
*) echo "fake: unknown command '$cmd'" >&2; exit 1 ;;
esac

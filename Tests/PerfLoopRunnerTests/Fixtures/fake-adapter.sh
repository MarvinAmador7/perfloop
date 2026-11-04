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
FAKE_GUARDED=0
FAKE_BLANK=0
FAKE_SNAP=same
FAKE_NOGUARDS=0
FAKE_ISO_FAIL=0
FAKE_SLEEP=0
FAKE_VERBS=

self="$0"
log() { if [ -n "$FAKE_LOG" ]; then echo "$*" >> "$FAKE_LOG"; fi; }
val() { grep "^$2=" "$1" | head -1 | cut -d= -f2; }
sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
jitter() { awk -v v="$1" -v n="$2" -v s="$3" 'BEGIN { srand(s); printf "%.3f", v * (1 + (rand() * 2 - 1) * n) }'; }
build() { echo "{\"commit\": \"$(val "$1" FAKE_COMMIT)\", \"dirty\": $(val "$1" FAKE_DIRTY), \"configuration\": \"release\", \"stamp\": true, \"builtAt\": \"2026-10-30T20:00:00Z\", \"hash\": \"sha256:$(sha "$1")\"}"; }
checks() { f=$(val "$1" FAKE_CHECK_FAIL); if [ -n "$f" ]; then echo "\"$f\""; elif [ "$2" = burst ] && [ "$(val "$1" FAKE_ISO_FAIL)" = 1 ]; then echo '"isolation-still"'; fi; }
# The guards PERFLOOP_GUARDS asks for, as deskbench reports them (exe scenario dir): built-within fails on a FAKE_BLANK
# build; snapshot-diff's capture is a "PNG" holding FAKE_SNAP, which the fake snapdiff compares byte for byte.
guards() {
  if [ -z "$PERFLOOP_GUARDS" ] || [ "$(val "$1" FAKE_NOGUARDS)" = 1 ]; then echo null; return; fi
  g=""; sep=""
  case ",$PERFLOOP_GUARDS," in *,built-within,*)
    bw=true; if [ "$(val "$1" FAKE_BLANK)" = 1 ]; then bw=false; fi
    g="{ \"name\": \"built-within\", \"pass\": $bw, \"detail\": \"fake columns built=$bw\", \"artifacts\": [], \"value\": 12, \"limit\": 300 }"; sep=", " ;;
  esac
  case ",$PERFLOOP_GUARDS," in *,snapshot-diff,*)
    mkdir -p "$3"; val "$1" FAKE_SNAP > "$3/$2-rep0.settled.png"; echo later > "$3/$2-rep0.settled.later.png"
    g="$g$sep{ \"name\": \"snapshot-diff\", \"pass\": true, \"detail\": \"captured\", \"artifacts\": [\"$3/$2-rep0.settled.png\", \"$3/$2-rep0.settled.later.png\"] }" ;;
  esac
  echo "[ $g ]"
}
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
  if [ "$FAKE_GUARDED" = 1 ]; then
  cat <<JSON
{ "schema": "perfloop.manifest/1", "protocol": 1, "app": "fake-app", "adapter": "fakebench",
  "scenarios": [ { "name": "step", "kind": "smooth", "params": { "steps": "8" }, "objective": "mainThreadCpuMsPerStep", "guards": ["checks", "built-within", "snapshot-diff"],
                   "guardParams": { "built-within.ms": 300, "snapshot-diff.tolerance": 0.005 }, "frameGuards": ["hitchTimeRatioMsPerS", "longestStretchMs"], "secondFixture": "swarm64" },
                 { "name": "burst", "kind": "isolation", "objective": "mainThreadCpuMsPerStep", "guards": ["checks", "built-within"] } ],
  "isolationGuards": ["burst"],
  "fixtures": [ { "name": "crew17" }, { "name": "swarm64" } ],
  "knobs": [ { "name": "reel.slide", "type": "choice", "default": "ca", "choices": ["ca", "clip"] } ], "hosts": ["scene"] }
JSON
  exit 0
  fi
  verbs=""; if [ -n "$FAKE_VERBS" ]; then verbs="\"verbs\": [\"$(echo "$FAKE_VERBS" | sed 's/,/", "/g')\"],"; fi
  cat <<JSON
{ "schema": "perfloop.manifest/1", "protocol": 1, "app": "fake-app", "adapter": "fakebench", $verbs
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
  log "ab $sc $fixture guards=$PERFLOOP_GUARDS params=$PERFLOOP_GUARD_PARAMS A=$a B=$b"
  if [ "$(val "$b" FAKE_AB_FAIL)" = 1 ] || [ "$(val "$a" FAKE_AB_FAIL)" = 1 ]; then echo "ab: child crashed" >&2; exit 2; fi
  if [ "$FAKE_SLEEP" != 0 ]; then sleep "$FAKE_SLEEP"; fi
  s=$$
  ca=$(cpu_of "$a" "$fixture" "" "$s"); cb=$(cpu_of "$b" "$fixture" "" "$((s + 7))")
  summ() { echo "{ \"reps\": 1, \"objective\": { \"name\": \"mainThreadCpuMsPerStep\", \"value\": $2 }, \"mainThreadCpuMsPerStep\": { \"n\": 1, \"median\": $2 },
    \"hitchTimeRatioMsPerS\": { \"median\": $(val "$1" FAKE_HITCH) }, \"longestStretchMs\": { \"median\": 40 }, \"steadyHz\": { \"median\": $(val "$1" FAKE_HZ) },
    \"lateFrames\": { \"median\": $(val "$1" FAKE_LATE) }, \"checksFailed\": [ $(checks "$1" "$sc") ], \"aNewField\": { \"x\": 1 } }"; }
  json="{ \"schema\": \"deskbench.ab/1\", \"scenario\": \"$sc\", \"fixture\": \"$fixture\", \"a\": \"$a\", \"b\": \"$b\", \"repsPerSide\": 1,
  \"summaryA\": $(summ "$a" "$ca"), \"summaryB\": $(summ "$b" "$cb"), \"comparison\": [], \"failures\": [], \"regression\": false, \"improvement\": false,
  \"objective\": \"mainThreadCpuMsPerStep\", \"guardsFailed\": [], \"notes\": [], \"buildA\": $(build "$a"), \"buildB\": $(build "$b"), \"counterbalanced\": true,
  \"guardsA\": $(guards "$a" "$sc" "$PERFLOOP_ARTIFACTS/A"), \"guardsB\": $(guards "$b" "$sc" "$PERFLOOP_ARTIFACTS/B") }"
  if [ -n "$out" ]; then echo "$json" > "$out"; fi
  echo "$json"
  ;;
run)
  sc=$1; shift; fixture=crew17
  while [ $# -gt 0 ]; do case "$1" in --fixture) fixture=$2; shift 2 ;; --reps|--set|--quiet-check) shift 2 ;; *) shift ;; esac; done
  log "run $sc $fixture knobs=$PERFLOOP_KNOBS guards=$PERFLOOP_GUARDS $self"
  c=$(cpu_of "$self" "$fixture" "$PERFLOOP_KNOBS" "$$")
  total=$(awk -v c="$c" 'BEGIN { printf "%.1f", c * 8 }')
  lat=$(awk -v c="$c" 'BEGIN { printf "%.2f", c * 3 }')
  step="{ \"name\": \"step\", \"atMs\": 0, \"durationMs\": 300, \"latencyMs\": $lat, \"frames\": { \"steadyHz\": 120 }, \"mainThread\": { \"cpuMs\": 1 }, \"bodies\": {}, \"notes\": [] }"
  fail=$(checks "$self" "$sc"); landed=true; if [ "$fail" = '"landed"' ]; then landed=false; fi
  iso=true; if [ "$fail" = '"isolation-still"' ]; then iso=false; fi
  cat <<JSON
{ "schema": "deskbench.result/1", "tool": { "name": "FakeBench", "version": "1", "configuration": "release", "build": $(build "$self") },
  "scenario": "$sc", "fixture": "$fixture", "params": {}, "profiled": false,
  "reps": [ { "index": 0, "steps": [ $step, $step, $step, $step, $step, $step, $step, $step ],
              "frames": { "steadyHz": $FAKE_HZ, "late": $FAKE_LATE, "hitchTimeRatioMsPerS": $FAKE_HITCH },
              "mainThread": { "cpuMs": $total, "longestMs": 40 }, "bodies": {},
              "checks": [ { "name": "landed", "pass": $landed, "detail": "" }, { "name": "isolation-still", "pass": $iso, "detail": "" } ],
              "guards": $(guards "$self" "$sc" "$PERFLOOP_ARTIFACTS"),
              "window": { "appActive": true, "keyWindow": true, "visible": true, "occluded": false },
              "worstStretches": [ { "step": "step#3 9→12", "durationMs": 40, "cpuMs": 39, "bodies": {},
                                    "topOurs": [ { "symbol": "ReelView.slide", "samples": 30 } ],
                                    "topFramework": [ { "symbol": "LayoutEngineBox.sizeThatFits", "samples": 36, "under": "ReelRepresentable" } ] } ] } ],
  "summary": { "reps": 1 }, "verdict": "pass", "exitCode": 0 }
JSON
  ;;
snapdiff)
  a=$1; b=$2; shift 2; tol=0.005; out=""
  while [ $# -gt 0 ]; do case "$1" in --diff-out) out=$2; shift 2 ;; --guard-param) case "$2" in snapshot-diff.tolerance=*) tol=${2#*=} ;; esac; shift 2 ;; *) shift ;; esac; done
  log "snapdiff $a $b tol=$tol"
  if cmp -s "$a" "$b" || awk -v t="$tol" 'BEGIN { exit !(t >= 0.2) }'; then pass=true; code=0; rev=null; else pass=false; code=3; rev=true; fi
  v=0; if ! cmp -s "$a" "$b"; then v=0.2; fi
  if [ -n "$out" ]; then echo diff > "$out"; fi
  echo "{ \"schema\": \"deskbench.snapdiff/1\", \"guard\": { \"name\": \"snapshot-diff\", \"pass\": $pass, \"detail\": \"fake: $v of the pixels differ\", \"artifacts\": [\"$a\", \"$b\", \"$out\"], \"value\": $v, \"limit\": $tol, \"review\": $rev } }"
  exit $code
  ;;
diff)
  log "diff $1 $2"
  echo "{ \"schema\": \"deskbench.diff/1\", \"a\": \"$1\", \"b\": \"$2\", \"gains\": [], \"losses\": [] }"
  ;;
*) echo "fake: unknown command '$cmd'" >&2; exit 1 ;;
esac

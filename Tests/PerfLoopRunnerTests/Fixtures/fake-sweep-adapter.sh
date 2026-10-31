#!/bin/sh
# A fake adapter for `perfloop sweep`: a parametric fixture `crew` (agents, items) whose CPU per step is
# 2 + 0.9 × agents + 0.01 × items (+ 3 ms with reel.slide=clip), with no window. FAKE_LOG gets one line per run;
# FAKE_BUSY_AGENTS marks that agents value's runs as on a noisy machine; FAKE_QUAD adds 0.02 × agents².
log() { if [ -n "$FAKE_LOG" ]; then echo "$*" >> "$FAKE_LOG"; fi; }
cmd=$1; shift
case "$cmd" in
describe)
  cat <<JSON
{ "schema": "perfloop.manifest/1", "protocol": 1, "app": "fake-app", "adapter": "fakesweep",
  "build": { "commit": "abc1234", "dirty": false, "configuration": "release", "stamp": true, "hash": "sha256:feed" },
  "scenarios": [ { "name": "step", "kind": "smooth", "params": { "steps": "8" }, "objective": "mainThreadCpuMsPerStep", "guards": ["landed"] } ],
  "defaultFixture": "crew17", "fixtures": [ { "name": "crew17" }, { "name": "crew", "parametric": { "agents": [1, 128], "items": [1, 2000] } } ],
  "knobs": [ { "name": "reel.slide", "type": "choice", "default": "ca", "choices": ["ca", "clip"] } ] }
JSON
  ;;
run)
  sc=$1; shift; fixture=crew17; reps=1; sets=""
  while [ $# -gt 0 ]; do case "$1" in --fixture) fixture=$2; shift 2 ;; --reps) reps=$2; shift 2 ;; --set) sets="$sets $2"; shift 2 ;; *) shift ;; esac; done
  log "run $sc $fixture reps=$reps knobs=$PERFLOOP_KNOBS sets=$sets"
  agents=17; items=90
  case "$fixture" in *@*) for kv in $(echo "${fixture#*@}" | tr ',' ' '); do
    case "$kv" in agents=*) agents=${kv#agents=} ;; items=*) items=${kv#items=} ;; esac; done ;; esac
  clip=0; case "$PERFLOOP_KNOBS" in *reel.slide=clip*) clip=3 ;; esac
  quiet=true; if [ "$FAKE_BUSY_AGENTS" = "$agents" ]; then quiet=false; fi
  q=${FAKE_QUAD:-0}
  r=0; out=""
  while [ $r -lt "$reps" ]; do
    cpu=$(awk -v a="$agents" -v i="$items" -v c="$clip" -v q="$q" -v r="$r" 'BEGIN { printf "%.3f", (2 + 0.9 * a + 0.01 * i + c + q * a * a + (r - 1) * 0.05) * 8 }')
    rep="{ \"index\": $r, \"steps\": [ {}, {}, {}, {}, {}, {}, {}, {} ], \"frames\": { \"hitchTimeRatioMsPerS\": 0.5 }, \"mainThread\": { \"cpuMs\": $cpu, \"longestMs\": 12 },
           \"checks\": [ { \"name\": \"landed\", \"pass\": true } ], \"window\": { \"appActive\": true, \"keyWindow\": true, \"visible\": true, \"occluded\": false } }"
    if [ -z "$out" ]; then out="$rep"; else out="$out, $rep"; fi
    r=$((r + 1))
  done
  cat <<JSON
{ "schema": "deskbench.result/1", "tool": { "name": "FakeSweep", "build": { "commit": "abc1234", "dirty": false, "configuration": "release", "stamp": true, "hash": "sha256:feed" } },
  "scenario": "$sc", "fixture": "$fixture", "reps": [ $out ], "noise": { "quiet": $quiet, "reasons": [] }, "verdict": "pass", "exitCode": 0 }
JSON
  ;;
*) echo "fake: unknown command '$cmd'" >&2; exit 1 ;;
esac

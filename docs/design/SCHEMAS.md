# Schemas

Every document `perfloop` or an adapter writes carries `"schema": "perfloop.<kind>/<n>"`. Rules, kept from
`deskbench.result/1`: within a version a field is never renamed or removed, only added; a reader of version n reads
n−1 (decoders for `deskbench.*/1` stay in `PerfLoopKit` and upgrade in memory); numbers are measured values rounded
as today (`Stats.round`), never interpolations; times are ms since the harness started unless named `*At` (ISO 8601).
JSON is pretty-printed with sorted keys (`JSONOut.encode`), so diffs of results are readable.

Exit codes stay: 0 pass · 1 usage · 2 harness error · 3 budget failed · 4 regression beyond noise · 5 untrusted.
Added: 6 refused (provenance: stale trace, unstamped binary, mixed runners) · 7 interrupted (the user touched the
machine; rerun).

## 1. Common objects

```jsonc
"build": {                       // perfloop.build/1, embedded wherever a binary is involved
  "hash": "sha256:…",            // of the executable file; the store's key
  "commit": "9bcd41a" | null,    // from the build stamp, not the cwd
  "dirty": false,                // uncommitted changes in tracked sources at build time
  "sourceHash": "sha256:…",      // tracked source paths' content hash: two clean builds of one commit agree
  "builtAt": "2026-10-30T15:31:02Z",
  "configuration": "release",
  "toolchain": "Xcode 27.1 (27A9275)",
  "stamp": true                  // false for binaries imported with `store import` (pre-stamp)
}
"machine": { …as today…, "runner": "local" | "ssh://mac-mini" | "vm:tart/…" }   // runner added
"tree": { "n": "symbol", "v": 123, "c": [ …tree… ] }     // folded call tree; v = samples (profile) or ms (diff)
```

## 2. `perfloop.manifest/1` (adapter `describe --json`)

```jsonc
{ "schema": "perfloop.manifest/1", "protocol": 1,
  "app": "capcomd-desktop", "adapter": "deskbench", "build": { …build… },
  "scenarios": [ {
      "name": "step", "summary": "…", "kind": "latency|smooth|isolation",
      "budget": "Reel scroll: no dropped frames at 120 Hz with 17 agents", "rule": "…", "latencyBudgetMs": null,
      "params": { "steps": "8" },
      "objective": "mainThreadCpuMsPerStep" | "instructionsPerStep" | "latencyMs",
      "guards": [ "landed", "built-within", "snapshot-diff" ],
      "guardParams": { "built-within.ms": 300, "snapshot-diff.tolerance": 0.005 },
      "frameGuards": [ "hitchTimeRatioMsPerS", "longestStretchMs" ],   // judged by their bands (Acceptance)
      "secondFixture": "swarm64",                // promotion needs not-worse here
      "fixture": "search",                       // optional (2026-11): the scenario's own fixture, before defaultFixture
      "host": "app"                              // optional (2026-11): runs inside the app (its window, menu bar, scene); absent: window
  } ],
  "isolationGuards": [ "burst", "typing" ],      // their checks run on every promotion, whatever the experiment climbs
  "fixtures": [ { …FixtureSpec as today…, "parametric": { "agents": [1, 64], "items": [50, 600] },
                  "accepts": { "items": "N, or LO-HI" } } ],   // optional (2026-11): values beyond a number in range, the adapter's to take
  "knobs": [ { "name": "reel.slide", "type": "choice", "default": "ca", "choices": ["ca", "clip"], "since": "0.7" },
             { "name": "build.perFrame", "type": "int", "default": 2, "range": [1, 8] } ],
  "hosts": [ "scene", "window" ], "defaultHost": "scene", "defaultFixture": "crew17",
  "fixtureSchemes": [ "file" ],                  // optional (2026-11): the scheme: forms --fixture takes; absent: any passes
  "harness": "PerfLoopHost",                     // optional (2026-11): the library answering the contract (doctor; ADAPTER.md §3b)
  "appearances": [ "light", "dark", "system" ],  // optional (2026-11, v11): what --set appearance= takes; absent: refused
  "textSizes": [ "large", "xLarge" ],            // optional (2026-11, v11): what --set textSize= takes (the bench applies it); absent: refused
  "probes": [ "Column", "ColumnHead", "ColumnThread", "EntryRow", "ColumnComposer", "CrewTab", "TitleBar", "OpenGroup", "Reel", "RootView", "DecisionBar", "FoldedDeck" ],
  "exitCodes": { "ok": 0, … } }
```

## 3. `perfloop.result/2` (from `deskbench.result/1`)

Everything in `deskbench.result/1` (`Results.swift`) stays with the same names and meaning. Added:

```jsonc
{ "schema": "perfloop.result/2",
  "tool": { …, "build": { …build… } },                 // ToolInfo.commit kept, now equal to build.commit
  "params": { …, "knobs": { "reel.slide": "ca", "build.perFrame": "2" } },   // the full knob vector, defaults included
  "profiled": false,                                   // true when a profiler was attached: never an objective input
  "appearance": "light" | "dark" | "system",           // PerfLoopHost (2026-11, v11): the look the reps drew in
  "textSize": "xLarge" | null,                         // the bench's text size, when --set textSize= asked for one
  "runner": "local",
  "summary": {
    …as today…,
    "objective": { "name": "mainThreadCpuMsPerStep", "value": 41.2, "dist": { …Dist… } },
    "mainThreadCpuMsPerStep": { …Dist… },
    "instructionsPerStep": { …Dist… } | null,          // null where counters read zero (VM)
    "hitchTimeRatioMsPerS": { …Dist… },                // in-process: Σ max(0, interval − steadyFrame) / step seconds
    "guardsFailed": [ "built-within" ]
  },
  "reps": [ {
    …as today…,
    "sampler": { "hz": 1000, "samples": 2310, "overheadPct": 0.6, "gateMs": 4 },
    "steps": [ { …as today…, "cpuMs": 38.9, "instructions": 61200000, "hitchTimeRatioMsPerS": 0.0,
                 "causes": [ { "keyPath": "AgentSlice.onScreen", "count": 2, "ids": 2,      // sets, distinct objects
                               "bodies": { "Column": 34, "CrewTab": 4 }, "objects": { "Column": 17, "CrewTab": 2 } } ],
                 "smoothness": { "positionErrorP95Pt": 0.8, "stalls": 0, "jerkP95": 1.9, "latencyFrames": 1, … } | null,   // §8
                 // PerfLoopHost, every step: the keyboard before the action and after the step settled (ADAPTER.md §6c)
                 "focus": { "before": { …focus… }, "after": { "keyWindow": { "title": "", "class": "NSWindow", "role": "bench" },
                            "mainWindow": { … }, "firstResponder": { "class": "NSTextView" }, "fieldEditor": true,
                            "editing": { "class": "NSTextField", "identifier": "filter", "label": "Filter" }, "inside": ["sidebar"] },
                            "expected": "#filter", "matched": true } | null,
                 // run.press / type / key / click
                 "input": { "kind": "press", "keys": "⌘F", "keyCode": 3, "characters": "f", "layout": "com.apple.keylayout.US",
                            "outcome": "fired",            // fired | fired-other | not-fired | delivered | hit | missed | nothing | undelivered
                            "menuItem": "Find…", "menuPath": "List › Find…", "expected": "Find…", "target": { "class": "Actions" },
                            "holder": null, "taken": null,  // not-fired: a disabled item with the keys; key-equivalent | responder | unhandled
                            "responder": { … }, "count": null, "unhandled": null, "asText": null,              // type
                            "point": null, "asked": null, "hit": null, "consumer": null, "consumerKind": null,   // click: view | gesture-recognizer | nobody
                            "recognizer": null, "notes": null,
                            "pictures": { "before": "/…/find-rep0-1-press-F.before.png", "after": "….after.png", "diff": "….diff.png",
                                          "changedPct": 3.2, "changedRect": [8, 6, 420, 30] } | null,   // points from the top-left
                            "line": "press ⌘F → fired menu 'Find…' (List › Find…) → Actions; focus: nothing (the bench window is key) → NSTextField #filter \"Filter\" (field editor)" } | null } ],
    "worstStretches": [ { …as today…,
                 "stacks": { …tree… } | null,          // folded, symbolised; null when the sampler was off
                 "samples": 231,
                 "topOurs": [ { "symbol": "ReelView.slide", "samples": 180 } ],
                 "topFramework": [ { "symbol": "LayoutEngineBox.sizeThatFits", "samples": 229, "under": "ReelRepresentable" } ],
                 "causes": [ … ],
                 "benchSamples": 200, "topBench": [ { "symbol": "Drive.inkOpened", "samples": 200 } ] } ],   // the bench's own code (2026-11)
    "guards": [ { "name": "snapshot-diff", "pass": true, "detail": "0.1 % of pixels differ", "artifacts": ["…/step-rep0.png"],
                  "value": 0.001, "limit": 0.005, "review": null },   // review: true = over tolerance, the owner decides
                { "name": "ink", "pass": false, "detail": "pane after open: blank: no pixel differs from its background (look at: …)",
                  "artifacts": ["…/ink/toggle-rep0-01-open-pane.png", …], "value": 0, "limit": 0.005,       // built in (2026-11)
                  "inkRegions": [ { "region": "pane", "after": "open", "pass": false, "ink": 0, "min": 0.005,
                                    "rect": [220, 0, 680, 700], "detail": "blank: …", "picture": "…/ink/toggle-rep0-01-open-pane.png",
                                    "alone": null } ] } ]   // alone: true = the region's view drawn by itself (2026-11)
  } ] }
```

**Looks (2026-11, v5).** A rep's `snapshot-diff` capture lists its picture, its `.later.png` and its layout
(`X.layout.json`, below). The runner replaces the candidate's record with the champion's `snapdiff` comparison, which
carries the regions:

```jsonc
{ "name": "snapshot-diff", "pass": true, "review": null, "value": 0.0011, "limit": 0.005,   // value: the whole window's share
  "detail": "footer resized (92×14 → 158×14 pt) [declared]; same: list, filter, details, rest; …",
  "artifacts": [ "runs/m0013/snapshot.png", … ],
  "looks": [ { "name": "footer", "look": "same|moved|differs|missing|resized", "share": 0.21,   // where it was, no shift
               "movedPt": [60, 0],                  // moved: by how much (right, down)
               "expected": true,                    // declared with --expect-look: the PR's reviewer accepts it
               "detail": "92×14 → 158×14 pt",
               "before": "…-footer.before.png", "after": "…-footer.after.png", "diff": "…-footer.diff.png" },   // a changed region's pictures
             { "name": "rest", "look": "same", "share": 0 } ] }   // `rest`: outside the named regions; `window` when none is named
```

`pass` is false (with `review: true`) when a region not declared with `--expect-look` changed; a change only in declared
regions passes, and its pictures are kept for the PR's reviewer. Two pictures drawn in different looks are not compared
(no `looks`, `review: true`).

`perfloop.snapshot/1`, the layout beside a snapshot (`X.png` → `X.layout.json`; rects in the picture's pixels from its
top-left corner):

```jsonc
{ "schema": "perfloop.snapshot/1", "size": [1800, 1400], "scale": 2, "appearance": "dark", "textSize": null,
  "regions": [ { "name": "footer", "rect": [20, 1360, 184, 28], "source": "identifier|view|rect|child window" },
               { "name": "thread", "rect": [440, 120, 900, 1200], "source": "view",
                 "compare": "ink", "inkAtLeast": 0.5, "inkMin": 0.005 } ],   // optional (2026-11): compared by its ink, not its pixels
  "missing": [ "filter" ],                                         // named, not found when the snapshot was taken
  "childWindows": [ { "name": "details", "kind": "DetailsPanel", "rect": [1248, 134, 520, 240],
                      "clipped": null, "material": null, "sheet": null } ],   // drawn in where they are on screen (v7)
  "notCaptured": [ "the title bars (the window's and its child windows')", "materials: 2 visual-effect view(s) drawn flat …" ] }
```

`checks[]` is unchanged; `guards[]` is the subset that gates acceptance plus the new ones. Both are counted per trusted
rep by every verdict (Checks.swift): a check passing in some trusted reps only is `flaky N/M`, a failure; `perfloop.measure/1`'s
`summary.checks[] { name, kind: check|guard, passed, of }` holds the counts (2026-11). `Budgets.evaluate` keeps
its rule text and adds nothing: the verdict words (`pass|fail|untrusted|regression`) are kept.

## 4. `perfloop.profile/2` (from `deskbench.profile/1`)

Kept: `template`, `trace`, `scenario`, `fixture`, `process`, `durationS`, `hitches`, `timeProfile`, `swiftUI`,
`signposts`, `inProcess`, `notes`. Added:

```jsonc
{ "schema": "perfloop.profile/2", "build": { …build… }, "machine": { … }, "runner": "local",
  "steps": [ { "name": "step#3 9→12", "startNs": …, "endNs": …, "source": "signpost|inProcess" } ],
  "tree": { …tree… },                    // main thread, whole recording, v = samples
  "treePerStep": [ { "step": "step#3 9→12", "tree": { …tree… } } ],
  "msPerStep": 312.4, "sampleIntervalMs": 1.0, "stepsCovered": 16, "stepsExpected": 16,
  "hitches": { …as today…, "timeRatioMsPerS": 60.4, "recordingS": 12.0 },
  "swiftUI": { "tables": [ …as today… ], "rows": { "swiftui-updates": 0, … },   // rows per table: 0 = recorded nothing
               "edges": { "label: changed-properties": 3 }, "changes": { "…": 1 },
               "rootCauses": [ { "cause": "DeskModel.onScreen", "updates": 33, "views": { "Column": 17, "CrewTab": 16 } } ],
               "longUpdates": [ { "view": "Column", "ms": 23.1, "cause": "…", "severity": "…" } ] } }
```

## 5. `perfloop.diff/1`

```jsonc
{ "schema": "perfloop.diff/1", "scenario": "step", "normalisation": "msPerStep",
  "a": { "build": { … }, "profile": "…/base-step-time.json", "msPerStep": 630.5, "steps": 16 },
  "b": { "build": { … }, "profile": "…/v3-step-time.json",   "msPerStep": 590.7, "steps": 16 },
  "deltaMsPerStep": -39.8, "deltaPct": -6.3,
  "tree": { "n": "main thread", "a": 630.5, "b": 590.7, "d": -39.8, "c": [ … ] },
  "gains":  [ { "path": ["…", "NSScrollAnimationHelper"], "a": 153.2, "b": 0.0, "d": -153.2, "under": "HostingScrollView" } ],
  "losses": [ { "path": ["…", "LayoutEngineBox.sizeThatFits"], "a": 0.0, "b": 384.0, "d": 384.0, "under": "ReelRepresentable" } ],
  "moved":  [ { "symbol": "propagate_dirty", "fromUnder": "ScrollViewCommitMutation", "toUnder": "sizeThatFits" } ],
  "provenance": { "stale": false, "crossOS": false, "allowed": [] },
  "notes": [ "signposts missing in a: steps aligned on the in-process result" ] }
```

## 6. `perfloop.experiment/1` and the ledger

```jsonc
{ "schema": "perfloop.experiment/1", "id": "0007", "createdAt": "…", "state": "new|built|screened|promising|inconclusive|rejected|full|won|lost|needsReview|promoted|abandoned|noRegression|regressed",
  "hypothesis": "sizeThatFits answers itself so Auto Layout never sizes 16 hosting views",
  "kind": "code" | "knob", "behaviourChange": false,
  "expectLook": [ "footer" ] | null,                             // 2026-11 (v5): regions whose look the change means to alter
  "expect": "same" | null,                                       // same: a feature or guard check (noRegression|regressed|inconclusive), never promoted
  "parent": { "experiment": "0005", "build": { …build… } },     // the champion at creation
  "patch": "exp/0007/patch.diff" | null, "knobs": { "reel.slide": "clip" } | null,
  "build": { …build… } | null,
  "scenario": "step", "fixture": "crew17", "secondFixture": "swarm64",
  "screen": { "pairs": 3, "results": [ "screen/a1.json", "screen/b1.json", … ], "objective": { "a": [..], "b": [..] },
              "wins": 3, "medianGainPct": 61.2, "band": 8.1, "guardsPassed": true, "guardReviews": null, "verdict": "promising",   // needsReview: a guard asks the owner; inconclusive: more pairs or the full
              "declaredLooks": [ "snapshot-diff in pair 1: footer differs 3.2 % [declared]" ] | null,   // 2026-11: passed, for the PR's reviewer
              "extendedTo": 6 },                                 // the pairs asked for, when `exp screen --more` added some
  "full":   { "repsPerSide": 5, "extendedTo": 8, "mwuP": 0.004, "effectPct": 58.9, "band": 7.0,
              "frameGuards": { "hitchTimeRatioMsPerS": { "a": 41.0, "b": 2.1, "pass": true }, "longestStretchMs": { … } },
              "verdict": "won" },
  "isolation": [ { "scenario": "burst", "pair": { … }, "pass": true, "failures": [] } ],   // after a won full
  "guardRuns": [ { "at": "…", "pair": { … }, "isolation": [ … ], "params": { … }, "override": null, "failures": [], "reviews": [] } ],
  "guardParams": { "snapshot-diff.tolerance": 0.01 } | null,     // the owner's, from perfloop guards --guard-tolerance
  "confirmation": { "hitchesTrace": "/Users/…/.perfloop/capcomd-desktop/traces/0007-step-hitches.trace", "timeTrace": "…", "profile": "exp/0007/profile.json",
                    "compositorHitchTimeRatioMsPerS": 3.4 },
  "diff": "exp/0007/diff.json", "explain": "exp/0007/explain.txt",
  "promotedAt": "…" | null, "pr": "https://github.com/…/pull/48" | null,
  "forced": true | null,                                         // an owner flag changed its course
  "ownerFlags": [ { "flag": "--force", "via": "env|tty", "command": "exp full", "effect": "ran the full over a screen that rejected it", "at": "…" } ] | null,
  "notes": [ "ran on local, idle-gated; 1 rep interrupted and redone" ] }
```

An expect-same stage (screen or full) has `"costs": [ { "metric": "mainThreadCpuMsPerStep", "champion": 40.1, "change": 0.2,
"low": -0.3, "high": 0.7, "margin": 2.0, "call": "same|worse|unsure" }, … ]`: the objective first, then each frame guard
both sides report, in the metric's units (`change` is the mean of candidate − champion over the pairs; `low`/`high` its
one-sided 95 % bounds, null with one pair; `margin` the metric's floor). Its ledger lines carry `"expect": "same"`.

`ledger.jsonl`: one line per state change, `{ "schema": "perfloop.ledger/1", "at": "…", "experiment": "0007",
"state": "promoted", "objective": { "before": 41.2, "after": 16.9 }, "build": "sha256:…", "by": "agent|owner",
"runner": "ssh://spare-mac.local", "machine": "Mac16,11", "ownerFlags": ["--force"], "ownerVia": "env|tty" }`
(`runner`/`machine` on a stage's line: where its numbers came from; `ownerFlags`/`ownerVia` on a line an owner flag
changed, and how the CLI saw it was the owner's: `PERFLOOP_OWNER=1` or a yes at a terminal). `state` is an
experiment's state, or one of: `session` (`session start`; `experiment` is `-`), `merged` (the champion's PR landed),
`measure` (`perfloop run`) and `baseline` (`perfloop baseline`, added 2026-11), whose `experiment` is the measurement's
id (`m0003`, `runs/m0003/run.json`). A `baseline` line from before then says `measure`; its `note` starts `baseline `
(a run's starts `run `), and the runner reads it as `baseline`. The stopping rules' time budget runs from the session's
first line that is an optimisation experiment's (none of these states, no `"expect": "same"`) and leaves out the time
an expect-same stage ran: from the line before its verdict (or guards) line to that line, when both are its own.

Every pair and stage records where it ran (C10): `"runner": { "runner": "local" | "ssh://host" | "vm:tart/NAME",
"model": "Mac16,11", "host": "spare-mac", "os": "26.6.2" }`. A pair without one predates runners and counts as
`local` on the store's Mac. A stage never mixes runners (acceptance says `error`; resuming a stage on another runner is
refused, exit 6). A pair the local runner aborted on input has `"interrupted": true` (never judged); the pair that
replaced it has `"interruptions": N`. A pair redone once (it failed, or a rep was untrusted) says why in `"redone"`.
Each side records what its trust was judged on, when the adapter said: `"trustworthy"` and `"windowFailed": ["keyWindow"]`,
`"exit"`, `"quiet"`, `"busyPct"`, `"busy"`. A stage with untrusted reps has `"untrusted": "4/6 reps untrusted: …"`, and its
verdict is `"untrusted"` when the pairs it needs are (ADAPTER.md §3, Trust).
`champion.json`: `{ "schema": "perfloop.champion/1", "experiment": "0007", "build": { … }, "merged": false,
"parents": ["0005", "0002"], "mergedAncestor": "9bcd41a", "objectives": { "step": 16.9, "switch": 153.2 }, "since": "…" }`.
`parents` is the chain of earlier champions back to the newest merged one, and `mergedAncestor` is that merged commit,
so the loop can climb on unmerged champions (owner's decision, SPEC §7) and every champion still traces back to `main`.
A champion set by hand (`champion set`, the owner's) has `"setBy": { "flag": "champion set", "via": "env|tty", "command":
"champion set", "effect": "…", "at": "…" }`; one that won its place has none. `champion merged SHA` writes the full
commit to `mergedAncestor` once it has checked SHA is on main and contains the build's commit. For a dirty champion
(its uncommitted changes can't be checked) it is the owner's: `"mergedBy"` records that use as `setBy` does (`"flag":
"champion merged"`), as do the champion's experiment (`ownerFlags`) and the `merged` ledger line.

`exp status --json` (`perfloop.status/1`, added 2026-11; before, a bare array of the open experiments): `{ "schema":
"perfloop.status/1", "open": [ …experiments… ], "timeBudget": { "budgetS": 7200, "startedAt": "…", "startedBy": "0003",
"spentS": 1380, "leftS": 5820, "notCountedS": 720 }, "stop": [ "…" ] }`. `timeBudget` is the stopping rule's clock
above: `startedAt`/`startedBy` (the first optimisation experiment's first line) are absent until it starts, and
`notCountedS` is the expect-same stages' time it left out. `stop` holds the stopping rules that hold (the text's `stop:`
lines).

## 7. `perfloop.sweep/1`

```jsonc
{ "schema": "perfloop.sweep/1", "scenario": "step", "fixture": "crew", "objective": "mainThreadCpuMsPerStep",
  "build": { … }, "reps": 2, "fixed": { "items": "100" },                       // --set with one value: not swept
  "axis": [ { "name": "agents", "role": "fixture", "values": [4, 16, 28, 40, 52, 64] } ],   // role: fixture | knob | param
  "points": [ { "agents": 4, "values": { "agents": 4 },                         // axis values flat (as here) and under values
                "objective": 6.1, "dist": { …Dist… }, "hitchTimeRatioMsPerS": 0.0, "longestStretchMs": 9.8,
                "guardsPassed": true, "checksFailed": [], "reps": 2, "result": "points/agents=4.json", "wallS": 21.4,
                "busy": false, "noise": null, "failure": null, "finishedAt": "…" } ],
  "fit": { "model": "linear", "axis": "agents", "n": 6, "slope": 0.92, "intercept": 2.3, "r2": 0.98, "adjustedR2": 0.975,
           "residuals": [ 0.1, -0.3, … ], "rmse": 0.2, "unit": "ms per step per agent" },
  "fits": [ { …linear… }, { "model": "quadratic", "quadratic": 0.004, … },      // per numeric axis, per slice of the others (`at`)
            { "model": "plane", "coefficients": { "agents": 0.9, "items": 0.02 }, … } ],   // every numeric axis at once (2+ axes)
  "notes": [ "budget of 10 min spent with 3 point(s) left: run the same command again to resume" ],
  "startedAt": "…", "finishedAt": "…", "complete": true }
```

`fit` is the headline: the line through the only numeric axis, or the plane when there are several. A quadratic is
fitted when an axis has ≥ 4 distinct values and reported as curving only when its adjusted r² beats the line's by more
than 0.02. Fits use every point with a number, busy ones included (they are marked; `--redo KEY` measures one again).
Fixture parameters reach the adapter in the fixture's name (manifest protocol 1): `--fixture crew@agents=24,items=100`,
for any fixture whose manifest entry has `parametric` (`{ "agents": [1, 128] }`: each parameter's accepted range).

## 7a. `perfloop.queue/1` (`<store>/queue.jsonl`)

```jsonc
{ "schema": "perfloop.queue/1", "at": "…", "item": "q3", "state": "queued", "experiment": "0007", "stage": "auto",   // auto | screen | full
  "runner": "ssh://spare-mac.local" | null, "force": true | null, "note": "…" }
{ "schema": "perfloop.queue/1", "at": "…", "item": "q3", "state": "running", "runner": "local", "note": "pid 4242 on local (Mac16,1, …)" }
{ "schema": "perfloop.queue/1", "at": "…", "item": "q3", "state": "waiting", "note": "waiting: last input 12 s ago < 120 s (frontmost: Xcode)" }
```

Append-only, like the ledger: an item's state is its newest line. `waiting` lines say why a runner didn't start a rep
(one per change of reason); `stopped` (`--until` reached, a signal) puts the item back in the queue, and its stage
resumes at the first missing pair; then `done` (the note is the experiment's new state) or `failed` (the error).

## 8. `perfloop.gesture/1`

```jsonc
{ "schema": "perfloop.gesture/1", "name": "flick-left", "recordedAt": "…", "device": "trackpad", "hz": 120,
  "synthetic": true | null, "source": "deskbench fling curve: …" | null,      // generated ones only
  "events": [ { "t": 0.0, "dx": -3.0, "dy": 0.0, "phase": "began", "momentum": "none", "precise": true }, … ] }
```

One gesture per file: the fingers touching (`mayBegin`/`began`) → lifting (`ended`/`cancelled`) → the system's
momentum ending, or 0.3 s after lifting when no momentum follows (PerfLoopProbe `GestureRecorder`). `t` is ms since the
first event; `dx`/`dy` are `scrollingDeltaX/Y` (points when `precise`, lines otherwise); `phase` and `momentum` are
`none | mayBegin | began | stationary | changed | ended | cancelled` (NSEvent's phases). `device` is `trackpad` (precise
deltas with phases) or `mouse` unless the recorder was told. `hz`: 1000 / the median interval of the events that moved.
A recorder writing several gestures names them `NAME`, `NAME-2`, … No text, no window contents, no identifiers; still,
recordings of a hand stay out of the repo (only synthetic ones are committed).

What a replay of one reports (`perfloop.result/2` `reps[].steps[].smoothness`; the rep's gestures together in
`reps[].smoothness`: the worst error, every stall, the median jerk; medians across reps in `summary.smoothness` as
`Dist`s):

```jsonc
"smoothness": { "positionErrorP95Pt": 0.0, "positionErrorMaxPt": 0.0, "latencyFrames": 1, "stalls": 0, "jerkP95": 32.1,
                "trackingTicks": 6, "ticks": 41 }
```

`latencyFrames`: the whole number of display frames (0–3) the content was behind the fingers, the alignment the error
is taken at; `positionErrorP95Pt`: |shown − expected| while the fingers were down (nil when no tick fell there);
`stalls`: frames the fingers moved ≥ 1 pt and the content < 0.5 pt, plus vsyncs with no tick meanwhile; `jerkP95`:
the shown position's third derivative, p95, touch to settle, in pt/frame³. The manifest's scenario lists
`positionErrorP95Pt` and `stalls` in `frameGuards`, and the manifest's `gestures` names the adapter's built-in ones
(`synthetic:flick-forward`, …), which its scenario's `gesture` parameter takes as well as a path.
`perfloop gestures list --json` prints `{ "schema": "perfloop.gestures/1", "dirs": [ … ], "gestures": [ { "path",
"name", "device", "events", "durationMs", "finger": [dx, dy], "momentum": [dx, dy], "synthetic", "problems" } ],
"builtIn": [ … ] }`.

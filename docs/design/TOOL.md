---
title: PerfLoop as a tool any Mac developer can use
date: 2026-11-04
status: gap analysis, plan, and where each item stands (local branch perfloop/tool, 2026-11-04; see §4)
---

PerfLoop works on capcomd Desktop today: the runner (`tools/perfloop`, generic, no capcomd imports) drives one adapter,
`deskbench` (`apps/menubar/app/Sources/CapcomdDeskBench` + `DeskBenchKit`, ~7,900 lines). This file lists what stands
between that and "a Mac developer adds PerfLoop to their own AppKit/SwiftUI app and their coding agent runs the loop on
it", ordered by how hard each gap blocks that developer, with a check that says when it is closed.

# 1. What a developer has to do today

To put a second app under the loop, a developer must write an executable that answers the runner's calls the way
deskbench does. Read from `PerfLoopRunner/Adapter.swift`, `Loop.swift`, `Guards.swift`, `PerfLoopKit/Readings.swift` and
the fake adapter in `Tests/PerfLoopRunnerTests/Fixtures/fake-adapter.sh`, the contract is:

| Verb | Who calls it | What must come back |
|---|---|---|
| `list --json` | `store add` (required) | `tool.build` with `stamp: true` and `hash` = the sha256 of the executable, else "unstamped" (exit 6) |
| `describe --json` | everything (optional: derived from `list`) | `perfloop.manifest/1`: scenarios with `objective` and `guards`, fixtures, knobs |
| `ab --a EXE --b EXE S --fixture F --reps 1 --json --out FILE [--set k=v]` | `exp screen/full` (the default `via`) | `deskbench.ab/1`-shaped: `summaryA/B` with the objective's median, `buildA/B`, `guardsA/B`, `failures` |
| `run S --fixture F --reps 1 --json --quiet-check 0 [--set k=v]` | knob experiments, `--via run`, sweeps | a result whose `reps[]` hold `steps[]`, `mainThread.cpuMs`/`longestMs`, `frames.*`, `checks[]`, `window{…}`, `guards[]`; exit 0/3/4/5 |
| `snapdiff A.png B.png --json --diff-out D [--guard-param k=v]` | when a scenario guards `snapshot-diff` | `{ "guard": { name, pass, detail, value, limit, review } }`, exit 0 or 3 |
| `diff A B --json` | `perfloop diff` | the adapter's differential call tree |
| env `PERFLOOP_KNOBS`, `PERFLOOP_GUARDS`, `PERFLOOP_GUARD_PARAMS`, `PERFLOOP_ARTIFACTS` | every windowed call | knobs read at start; the guards named run after each rep; their files under the artifacts dir |

Nothing of this is written down outside the code, and nothing helps write it: the measuring parts (stretch clock, frame
timing, thread CPU, instructions, the main-thread sampler, window trust, snapshots, the build stamp plugin, the result
schema) all live inside deskbench and import capcomd modules next to generic code. `PerfLoopProbe` has knobs, mutation
records and gestures, but not the body/event probe seam (`DeskProbe` is capcomd's). The realistic estimate for a second
app today is "copy deskbench and delete half of it": days, and every schema detail rediscovered from the runner's reads.

# 2. Gaps, by impact

Each item: why it blocks, what closes it, and the acceptance check. Status is kept current at the end of the branch.

## G1. A reusable adapter host (blocks everything else)

*Why.* Every adapter would reimplement the measurement core and the CLI contract above.

*What.* A macOS-only library `PerfLoopHost` in the package. An app's bench target registers fixtures, scenarios (an
async closure that shows a view and runs steps), knobs and checks, and calls `Bench.main()`; the library gives it the
whole contract: `list`, `describe`, `run`, `snapdiff`, `knobs`, `help`; the result JSON (`perfloop.result/2`, the fields
`Readings` reads); per-step main-thread CPU, instructions retired, latency, display-link frames and hitch time ratio;
the stretch clock; window trust; body counts through a generic `Probe` seam (added to `PerfLoopProbe`); `checks` and the
`snapshot-diff` guard (window PNG after settle, pixel diff by the champion's `snapdiff`); the build stamp, via a
`PerfLoopStamp` build-tool plugin moved into the package. No `ab`: the manifest gains an optional `verbs` list and the
runner measures through `run` (interleaving itself) when an adapter has no `ab`.

*Acceptance.* `swift build` and `swift test` in `tools/perfloop` stay green; `check-imports.sh` passes; host tests (no
window) cover the CLI's headless verbs, the step/frame arithmetic, the result shape read back through `Readings`, and the
snapshot pixel diff; a runner test drives an adapter without `ab` through `exp new` → screen with no `--via`; deskbench's
tests still pass, its manifest is unchanged.

## G2. The adapter contract, written down and checkable

*Why.* Schema drift between an adapter and the runner shows up as "no objective" mid-experiment.

*What.* `tools/perfloop/ADAPTER.md`: the verbs, flags, env vars, exit codes and the minimal result fields, with the
schema versions. `perfloop doctor --bench PATH` runs the headless half of the contract against an adapter (stamp and
hash, manifest decodes, every scenario's objective is one the runner knows, guards it can judge, knob defaults inside
their choices, `snapdiff` present when a scenario guards snapshots) and says what to fix, one line each.

*Acceptance.* A runner test runs `doctor --bench` on the fake adapter (pass) and on broken copies (unstamped, wrong
hash, unknown objective, snapshot guard without `snapdiff`): each failure is named with its fix; exit 0 / 1.

## G3. A second app, end to end

*Why.* SPEC §2.1's extraction criterion, and the only proof that G1 is enough.

*What.* `tools/perfloop/Examples/SlowList`: its own package that depends on `../..` (as an outside app would), an
AppKit + SwiftUI list app with a deliberately slow path (every row's body recomputes its rank by sorting the whole
list), a knob for the fast path, a compile-time fix for a code experiment, a deliberately cheating build (blank rows),
its adapter (`slowlist-bench`, ~150 lines on `PerfLoopHost`), headless tests, and `walkthrough.sh`: store add →
champion → knob experiment → code experiment screen → full → promote; the cheat screened and refused; explain at each
step. A dry-run mode prints the commands without opening windows.

*Acceptance.* `swift build` and `swift test` in the example; `walkthrough.sh --dry-run` prints the plan; one real
short run on this Mac (window lock held) shows: the code fix promising and won, the cheat not promoted (guards), and
`explain.txt` naming the slow stretch. Numbers recorded in the example's README, binaries and stores deleted after.

## G4. Setup: `perfloop init`

*Why.* Even with G1, a developer must know which targets, plugin and files to add.

*What.* `perfloop init --app NAME [--dir DIR] [--target NAME]` writes an adapter target skeleton (`Sources/<Name>Bench/
main.swift` with one scenario, one knob and a check), the agent procedure (`PROGRAM.md`) and prints the `Package.swift`
lines to add (it never edits a Package.swift it didn't create; `--package` writes a standalone one).

*Acceptance.* A test runs `init` into a temporary directory and checks the files; once by hand: the generated package
builds against `tools/perfloop` and its `describe --json` passes `doctor --bench`.

## G5. Diagnosis: `perfloop doctor`

*Why.* The loop's numbers are only as good as the machine; today the reasons a run is untrusted surface one at a time
(locked screen, no xctrace, a busy Mac, a full disk, a store inside a repo).

*What.* `perfloop doctor [--bench PATH] [--runner R] [--json]`: macOS version and model; `xcrun xctrace` present (only
needed for profiles); Developer Mode (`DevToolsSecurity -status`, informational); console session and screen lock; idle
time and the frontmost app; free disk on the store's volume (warn under 20 GB, fail under 5); the store's location and
whether it is inside a git checkout; `PERFLOOP_HOME`/`PERFLOOP_APP`; with `--bench`, G2's checks; with `--runner ssh://…`,
`runner check`. Each line `ok | warn | fail` with the fix. Exit 1 on any fail.

*Acceptance.* Runner tests with fake `ioreg`/`df`/`xcrun` (as the idle gate's tests already do): each state gives its
line and the exit code; `--json` is `perfloop.doctor/1`.

## G6. Docs for humans and agents

*What.* `tools/perfloop/README.md` (what it is, a 10-command quickstart on the example, the verbs, where data lives,
privacy), `ADAPTER.md` (G2), `AGENTS.md` (how a Claude Code or Codex agent drives the loop: the loop, stopping rules,
what it must never edit or commit, the owner's checkpoints; written to be copied into an app's repo or loaded as a
skill), and a schema table (every `perfloop.*` document, its version, its stability).

*Acceptance.* The quickstart's commands are the walkthrough's; every verb in `perfloop help` appears in the README.

## G7. Genericity and robustness left in the runner

- `exp new` refuses patches touching `.relay/`, `.traces/`, `.capcomd` (capcomd's rules) hard-coded in the generic
  runner: make the list come from the manifest (`privatePaths`), keep `.trace` always. *Check:* a test with a manifest
  that lists a path; deskbench's describe lists capcomd's three, so its behaviour is unchanged.
- No CI runs `tools/perfloop`'s own tests or `check-imports.sh` (the menubar workflow only builds it as a dependency),
  and the SPEC's Linux job for `PerfLoopKit` doesn't exist. *Check:* a step in `.github/workflows/menubar.yml` (local
  commit; pushing is the owner's call); `swift build` of `PerfLoopKit`/`PerfLoopRunner` and `swift test --filter
  PerfLoopKitTests` pass in a Linux container (`swift:6.0`), with `PerfLoopHost` and `PerfLoopProbe` compiled out there.
- Error messages that name deskbench (`gestures list` help). *Check:* grep.

## G8. Senses still inside deskbench (not blocking a first adopter)

- The main-thread sampler (C1) and its stack folding (`Sampler.swift`, `DeskBenchKit/Stacks.swift`): generic code in
  the adapter. Move the folding into `PerfLoopKit` and the sampler into `PerfLoopHost`, so `worstStretches[].stacks`,
  `topOurs` and `topFramework` come for free. *Check:* the host's result for a scenario with a deliberately long stretch
  names the slow function in `topOurs` (example run).
- xctrace profiles, call trees and `diff` (C2: `XCTrace.swift`, `CallTree.swift`, `Diff.swift`, `XMLLite.swift`) and
  cause records (C7) are deskbench-only; `perfloop diff` on a host adapter has no `diff` verb to call.
- Gesture replay (C9) needs an `NSScrollView` driver in the host.
- deskbench itself still carries its own copies; moving it onto `PerfLoopHost` is a follow-up that must keep its 77
  bench tests and its manifest byte-identical, so it is not done here.

## G9. Owner decisions, not code

Extraction (Phase 5: the criterion "a second app adopts it" is met by G3 only in spirit: the example is ours), the
package and product names, the licence file, whether `PerfLoopHost`'s API is stable enough to tag. See the end of the
branch's report.

# 3. Phases

1. G1 host library (probe seam, stamp plugin, `verbs` + runner `via` default) — the minimum an outside app needs.
2. G2 contract doc + `doctor --bench`.
3. G3 example app, adapter, walkthrough; one real run.
4. G4 `init`.
5. G5 `doctor` machine checks.
6. G6 README, AGENTS.md, schema table.
7. G7 genericity, CI step, Linux check.
8. G8 the sampler into the host, if time allows; the rest stays listed.

Each phase is one or more focused commits; every commit keeps `swift build`, `swift test` and `check-imports.sh` green
in `tools/perfloop`, and the deskbench tests where `apps/menubar/app` is touched.

# 4. Where it stands (end of the perfloop/tool branch, 2026-11-04)

| Gap | Status | What closes it / what's left |
|---|---|---|
| G1 adapter host | done | `PerfLoopHost` (Bench, Run, Recorder, StretchClock, MainThreadSampler, snapshots, result), `Probe` in PerfLoopProbe, `PerfLoopStamp` plugin, manifest `verbs`, runner measures through `run` without `ab` |
| G2 contract + `doctor --bench` | done | `tools/perfloop/ADAPTER.md`; `perfloop doctor --bench`, tested on the fake adapter and five broken copies |
| G3 second app | done | `Examples/SlowList`; the walkthrough ran on this Mac: knob promising (−85.7 %), cheat rejected by `rows-drawn` although its objective won 3/3, fix won in full (p = 0.0079) and promoted; a sweep fits 0.07 ms/row on the slow path. Numbers in its README |
| G4 `perfloop init` | done | scaffold (+ `--package`) checked by hand: builds against the package, passes doctor, runs |
| G5 `doctor` machine checks | done | screen lock, idle and call apps, load, disk, store in a checkout, xctrace, DevToolsSecurity, platform; scripted in tests |
| G6 docs | done | `README.md` (quickstart, commands, products), `AGENTS.md` (agent rules), schema table in `ADAPTER.md` §8 |
| G7 genericity, CI, Linux | done | `privatePaths` from the manifest (capcomd's list only for deskbench-era manifests); CI steps and a `perfloop-linux` job in the menubar workflow (not pushed); Linux: 147 tests, 1 skipped (macOS-only fake remote) |
| G8 senses still in deskbench | partly | sampler and stack folding now in the package (host + Kit); still deskbench-only: xctrace profiles, call trees and `diff` (now refused with a reason on host benches), gesture-replay drivers, deskbench's own move onto PerfLoopHost |
| G9 owner decisions | open | extraction, names, licence file, API stability: see the branch report |

Found on the way, fixed: `cacheDisplay` snapshots in dark mode were text on transparency (the bench window now has a
pinned light appearance and snapshots are composited on the window background); the snapshot guard's own PNG encoding
showed up as a step's worst stretch (guards now run after the last step's stretch closes); a guard reading row titles from
the accessibility tree saw 1 of ~15 rows (SwiftUI builds that tree lazily) and was replaced by one counting
`Probe.body("RowContent", id:)`, with the snapshot as the backstop.

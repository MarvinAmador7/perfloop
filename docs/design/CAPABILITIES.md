# The ten capabilities, as components

Each entry: what it is, its API and CLI, the data it writes (schema names in SCHEMAS.md), feasibility with what was
verified (probes in `probes/`, FEASIBILITY.md) and what is assumed, and risks. Numbering follows the ranked list
from the session. "Today" refers to `apps/menubar/app/Sources/CapcomdDeskBench` and `DeskBenchKit` at 9bcd41a.

## C1. In-process main-thread sampler (`PerfLoopProbe.Stretch`)

**What.** A background thread that, while a main-thread stretch is open (the run-loop observer has seen
`afterWaiting` and not yet `beforeWaiting`), suspends the main thread every 1 ms, reads its registers
(`thread_get_state`, `ARM_THREAD_STATE64`), walks frame pointers (`x29`) to the stack top, resumes it, and stores the
addresses in a preallocated ring. After the run the addresses are symbolised with `dladdr` and folded into a call
tree per stretch. Every `worstStretches[]` entry carries its stacks; xctrace becomes the confirmation tool.

**Design.**
- Gate: the observer sets an atomic flag at `afterWaiting`, clears it at `beforeWaiting`. Sampling runs only while
  set, and only after the stretch has lasted ≥ 4 ms (a stretch shorter than half a 120 Hz frame is not worth
  stacks; this also keeps the cost near zero on a healthy build). Rate 1 kHz, configurable (`--sample-hz`).
- No heap allocation between `thread_suspend` and `thread_resume`: a fixed ring of 64 K frames × 8 bytes, written by
  index (Chromium's rule for its Mac sampler, FEASIBILITY.md ref 7). Symbolisation happens after the scenario.
- Stack walk bounds: `pthread_get_stackaddr_np`/`pthread_get_stacksize_np` of the main thread; stop on misaligned fp,
  fp not increasing, depth 128.
- Attribution: a sample belongs to the stretch open at its time; stretches keep `[sampleIndexRange]`. The call tree
  per stretch is built in `PerfLoopKit` from addresses + symbols (same tree type as C2).
- Costs reported in the result: `sampler.samples`, `sampler.overheadPct` (sampler thread CPU / main-thread CPU).

**CLI.** On by default in `run`; `--no-sampler` turns it off; `--sample-hz 2000` for short stretches.
`explain` prints, per worst stretch, the top 5 inclusive frames that are ours or in the hot list, then the hottest
framework subtree.

**Data.** `perfloop.result/2`: `reps[].worstStretches[].stacks` (folded tree, `{n, v, c}` nodes with symbol names;
addresses dropped after symbolisation), `reps[].sampler`.

**Feasibility.** Verified today on this Mac (M1 Pro, macOS 27.0.1), probe `probes/sampler`: 3000 samples in 3 s at
1 kHz, 0 failures, per-sample cost p50 7.3 µs, p95 14.8 µs, max 78 µs; main-thread throughput loss 0.73 %; the
inclusive shares of a known 90/10 workload came out 90.5/9.4. `dladdr` resolved local (non-exported) symbols in the
shared cache (`probes/symbolicate/scan.swift`: 296 distinct names over 400 probes inside AttributeGraph, including
`GCC_except_table8`-style locals), so `AG::Graph::propagate_dirty`-level names are expected without atos.
Prior art: Sentry's iOS profiler and Emerge's ETTrace sample the main thread this way (refs 6, 8).

**Risks.**
- Deadlock if the sampler allocates or logs while the target is suspended (it must not; test with a malloc-heavy
  main thread under sampling for minutes).
- `dladdr` names the nearest preceding symbol: inside unsymbolised ranges it misattributes. Mitigation: Phase 1
  compares one sampled run against the same run's xctrace tree and reports the agreement; `atos -p <pid>` as a
  fallback while the child is alive (the protocol's `exit` handshake exists for this).
- The sampler thread competes for a core on a loaded machine; its own CPU is measured and reported.
- Not for arm64e processes (pointer authentication would need `ptrauth_strip`); the bench is arm64.

## C2. `perfloop diff`: differential call tree

**What.** Two profiles (xctrace exports or sampler trees), normalised per step, folded into one tree where each node
has `a`, `b`, `delta` in ms per step; the top gains and losses as subtrees, "moved" subtrees detected by name, and
an `explain` that says what to look at.

**Design.**
- Input: `perfloop.profile/2` (which carries the tree already) or `.trace` files (exported on the fly; 3 s and 6 MB for
  10 k samples, verified). Steps come from the `step` signposts (`os-signpost` table); samples outside steps are a
  separate "idle" bucket so settle time and warming are not blamed on a step.
- Normalisation: ms per step (samples × interval ÷ steps), so a 12 s recording with 14 steps compares with one
  with 16.
- Folding: frames cleaned as today (`ProfileSummary.clean`), chains that never branch collapsed (as `build_deep.py`
  did), generic noise (`objc_msgSend`, `swift_retain`) kept as leaves but not ranked.
- Ranking: subtrees by |delta|, each reported once (a child is not re-reported under its parent unless its own delta
  differs by > 20 %). "Ours" (symbols in the app's modules) listed first; framework subtrees carry their nearest
  app frame ("under `ReelView.slide`").
- Provenance: both sides' `build.hash` must be the champion's or an experiment's in the ledger; otherwise refuse
  unless `--allow-stale` (defence for incident 5).

**CLI.** `perfloop diff A B [--scenario step] [--per step|run] [--top 12] [--json]`; `perfloop diff --champion --exp 0007 step`.
`deskbench trace --diff A.trace B.trace` in Phase 1 before the split.

**Data.** `perfloop.diff/1`.

**Feasibility.** Verified: the export path, timing and the tree construction (`parse.py` did it in Python today).
The signpost table was empty in two of the session's recordings (`signposts:` printed nothing in
`base-step-time.log`): the step boundaries then fall back to the in-process result's `steps[].atMs` aligned on the
first main-thread burst (assumed workable; the `runloop-events` table is a second anchor).

**Risks.** Symbol churn between OS versions makes "same name" matching fail across machines: `diff` refuses when
`machine.os` differs unless `--allow-cross-os`. Deep SwiftUI stacks (depth 100+) make the tree wide; collapsing
unbranched chains and a `--depth` limit keep the JSON small.

## C3. A low-noise objective and rate-invariant frame metrics

**What.** `mainThreadCpuMsPerStep` (thread CPU clock, exists per stretch) and `instructionsPerStep`
(`proc_pid_rusage` `ri_instructions`) as the objectives; hitch time ratio (ms of lateness per second) in-process
and from the compositor; the frame metrics kept as guards.

**Design.**
- CPU ms: sum of `Stretch.cpuMs` for stretches inside steps ÷ steps. Already measured; promote to `Summary`.
- Instructions: `proc_pid_rusage(getpid(), RUSAGE_INFO_V4)` before and after each step (the struct pointer is passed
  as the `rusage_info_t *`; see the probe for the cast). Process-wide: the bench process's other threads (SwiftUI's
  own, I/O for nothing, the sampler) are small and constant; reported as a second column, never silently replacing
  CPU ms. In a VM it may read zero: the result says `instructions: null` and the runner falls back.
- Hitch time ratio in-process: Σ over display-link intervals of max(0, interval − steadyFrame) during steps ÷ step
  seconds, in ms/s. Compositor hitch time ratio from the `hitches` table: Σ duration ÷ recording seconds. Apple's
  bands: < 5 ms/s good, 5–10 noticeable, > 10 needs action (WWDC20, ref 10; the Organizer uses a wider scale, ref 11).
- `lateFrames`, `frameP95Ms` stay in the result and in `explain`, printed after `steadyHz`, never used to decide.

**CLI.** `--objective cpu|instructions|latency` on `ab`, `compare`, `exp`; the manifest sets the default per scenario.

**Data.** `Summary.objective`, `Summary.hitchTimeRatioMsPerS`, `StepResult.cpuMs`, `StepResult.instructions`,
`ProfileResult.hitches.timeRatioMsPerS`.

**Feasibility.** Verified (probe `probes/rusage`): counters readable as uid 501 without root, 150.04 M instructions
per identical run with CV 0.01 % (cycles 0.09 %) where wall and CPU time had CV 9–15 % on a busy machine. The
CPU Counters xctrace template also recorded against a plain process as a normal user today (FEASIBILITY.md §1.4),
but `kpc` is documented as root-or-entitlement and had permission regressions on macOS 15.3.1 and 27.0.1 (refs 3–5),
so it is not on the critical path. CPU ms exists today.

**Risks.** CPU ms is not fully deterministic (frequency scaling, E vs P core placement: `thread_info` CPU time is
wall-clock-on-core, so an E-core run reads longer). Mitigation: `ProcessInfo.beginActivity(.latencyCritical)` is
already asserted; report `CoreTypeByThread` when a CPU Counters confirmation runs; instructions as the tie-breaker.
Instructions reward doing the same work in fewer instructions and do not see memory stalls; the frame guards and
compositor hitch ratio keep the loop honest.

## C4. Runtime variant knobs

**What.** Named, typed switches read at the use site so one binary holds several variants; set per run from the CLI;
swept without rebuilding.

**Design.**
- `public struct Knob<T: KnobValue>`: `Knob("reel.slide", default: "ca", choices: ["ca", "clip"])`,
  `Knob("build.perFrame", default: 2, range: 1...8)`. First read parses `PERFLOOP_KNOBS` (`k=v,k=v`), caches in a static;
  later reads are a load. Registration is static so `describe` can list all knobs with defaults and choices.
- The runner passes `--set knob:reel.slide=clip` to the child, which exports `PERFLOOP_KNOBS`. Results carry the full
  knob vector (`params.knobs`), including defaults, so two results are comparable only if their vectors agree or
  the difference is the experiment.
- Knobs are for experiments: a promoted knob becomes the default in a follow-up change and the knob is deleted
  (§5.4 of SPEC.md). The ledger flags knobs older than one phase.

**CLI.** `perfloop run step --set knob:reel.slide=clip`; `perfloop ab --a-knobs … --b-knobs …` for same-binary A/B;
`perfloop sweep step --set knob:build.perFrame=1..8 --reps 3`.

**Data.** `manifest.knobs[]`, `result.params.knobs`, `perfloop.sweep/1`.

**Feasibility.** Straightforward Swift. The two first knobs are real: the reel's slide (`ReelView.slide`, a
`CABasicAnimation` on `position.x`) vs the clip-view scroll animation it replaced; the per-frame column build count
in the heads-first open.

**Risks.** A knob at a hot site read via dictionary every frame would be a knob-shaped regression: the static cache
is mandatory and the probe seam's cost rule (a nil check) applies. Knob debt: see the policy.

## C5. Experiment ledger with a champion

**What.** A content-addressed store of builds with their stamp; experiments with hypothesis, patch, knobs, screen
and full results, verdict and trace paths; a champion pointer; `exp` verbs; resumable.

**Design.**
- Build stamp: an SwiftPM build-tool plugin writes `BuildStamp.swift` with `commit`, `dirty`, `builtAt`,
  `configuration`, `sourceHash` (hash of tracked source paths, so two clean checkouts of the same commit match);
  the binary's own `sha256` is computed by the store on import. `ToolInfo.commit` comes from the stamp;
  `gitHead()` is removed (it is the cwd bug).
- Store: `builds/<sha256>/{bin, bundles, build.json}`; `exp/<id>/{experiment.json, patch.diff, screen/*.json,
  full/*.json, diff.json, explain.txt}`; `ledger.jsonl` (one line per state change, append-only); `champion.json`.
- `exp new "<hypothesis>" [--kind code|knob] [--knobs …] [--scenario step] [--fixture crew17]`: records the working
  tree's diff against the champion's commit, builds (`swift build -c release`), imports the binary, runs the screen
  (SPEC §5.1), writes `explain.txt`, prints the verdict. `exp full`, `exp promote` (checks guards, requires
  `dirty == false`, records the confirmation traces, moves `champion.json`, appends to the ledger). `exp status`
  lists open experiments and what each needs next. `exp replay <plan.json>` runs a list (SPEC §6.1).
- Resumable: every step writes before it starts the next; `exp resume` picks up at the first missing file.

**CLI.** As above, plus `perfloop store import <bin> --commit <sha> --note …` for pre-stamp binaries, `perfloop ledger
[--json]`, `perfloop champion`.

**Data.** `perfloop.build/1`, `perfloop.experiment/1`, `perfloop.ledger/1` (JSONL of experiment states).

**Feasibility.** Plain file plumbing. The plugin needs `git` at build time; when absent (CI tarball) the stamp says
`commit: null, dirty: true` and promotion is refused.

**Risks.** Store size: binaries are 46 MB each (today's `bench-good`); keep the last 20 and every champion, `perfloop
store gc`. Patches must never include secrets: `exp new` refuses diffs touching `.relay/`, `.traces/`, `~/.capcomd`
paths (the repo's rule).

## C6. Correctness guards

**What.** Checks that make "fast because wrong" lose: the reel landed; visible columns fully built within N ms; the
post-settle window matches the champion's; isolation unchanged. Read from the champion's manifest, not the
candidate's.

**Design.**
- `landed` exists. `built-within N`: after settle, each on-screen column must have had `Column`, `ColumnHead`,
  `ColumnThread` bodies and ≥ 1 `EntryRow` body (fixture-known counts), with the last of them ≤ N ms after settle
  (N from the manifest, default 300 ms); plus `snapshot` → the view dump's on-screen `NSHostingView`s have non-empty
  subtrees.
- `snapshot-diff`: PNG of the window after settle (today's `snapshot`, no screen recording permission) compared
  with the champion's for the same scenario step: per-pixel difference ratio and a per-column bounding-box check;
  tolerance from the manifest (default 0.5 % of pixels), with a mask for the clock/time text. Over tolerance ⇒ the
  experiment is `needsReview` with both PNGs in `exp/<id>/`, never a win.
- Isolation checks (`burst`, `typing`) run as guards on every promotion even when the experiment targets `step`.
- Guards are declared in the adapter and listed in the manifest; the runner takes the champion's list so a candidate
  cannot drop one.

**CLI.** `perfloop guards --exp 0007` re-runs guards only; `--guard-tolerance` is refused inside `exp` (owner-only).

**Data.** `result.guards[]` (name, pass, detail, artifacts), alongside `checks[]` which stays as is.

**Feasibility.** The snapshot and view dump exist (`Harness.snapshot`, `dump`). Pixel comparison on `NSBitmapImageRep`
is simple. The fixture is deterministic ("same name, same bytes"), so snapshots are comparable across builds except
for relative timestamps: the mask handles `TimeDataFormatting` text, or the fixture pins "now".

**Risks.** Over-tight tolerance makes every font-rendering change a review; start loose, tighten with data. A guard
that depends on body counts can be gamed by not calling the probe: the probe calls are in the app code the owner
reviews, and the ledger shows the body totals per view type next to the gain.

## C7. "Why did this body run" records

**What.** Which observed property changed before a body ran, mapped onto stretches, from two sources: cheap
in-process mutation records, and the SwiftUI instrument's cause tables as confirmation.

**Design.**
- In-process: `Mutations.record("DeskModel.focused")` at the model's setters that matter (hand-placed, or via a
  thin `@Observable` wrapper that calls `withMutation(keyPath:)` and forwards the key path to the probe when a sink
  is attached). Each record is `(t, keyPath, id?)`. Attribution: bodies in the next run-loop turn's update are
  charged to the set of mutations since the previous update; a stretch's `causes` is that set with body counts.
  This is coarse (a turn, not an edge) but answers "a tab click re-evaluated Column×17 because `onScreen` and
  `focused` changed", which is what H1 and H7 needed.
- Confirmation: `profile --template swiftui` exports `swiftui-causes` (`source-node`, `destination-node`,
  `changed-properties`, `label`, `layout-info`), `swiftui-updates` (`view-name`, `root-causes`, `cause-graph-node`,
  `downstream-cost`, `duration`, `severity`), `swiftui-update-groups` (`cause-backtrace`), `swiftui-changes`
  (`description`, `backtrace`). Columns verified today from the template's table schemas (FEASIBILITY.md §1.5); the
  rows' content on a real run is not yet seen. `ProfileResult.swiftUI` becomes a summary of root causes by view.

**CLI.** `explain` prints, per worst stretch, `causes: onScreen (Column×17, CrewTab×16), focused (…)`. `perfloop causes
<result.json>` prints the whole table.

**Data.** `reps[].worstStretches[].causes[]`, `reps[].steps[].causes`, `profile.swiftUI.rootCauses[]`.

**Feasibility.** The in-process half is a probe call and a time join. The SwiftUI-template half depends on Apple's
schemas staying exportable; today the Instruments 27.1 template defines them; WWDC25 session 306 describes the
Cause & Effect graph (ref 2).

**Risks.** `@Observable` does not expose a public "which key path changed" hook on the observer side; the
registrar-wrapper approach instruments the model, not SwiftUI, so changes SwiftUI tracks through environment or
preferences are not attributed (shown as `causes: []`). The SwiftUI template records at 100 µs and is heavy; it is
confirmation only.

## C8. Scaling sweeps and real fixtures

**What.** `--sweep` over fixture parameters and knobs to fit cost curves (ms per step vs agents, vs items); fixtures
captured from a daemon and anonymised.

**Design.**
- Sweep: `perfloop sweep step --fixture crew --set agents=4..64/4 --set items=50..400/50 --reps 3` runs the grid
  (fixtures generated on the fly from a parametric spec, which `Fixtures` already is), reports the objective per
  point and a fitted linear/quadratic slope with residuals; the `swarm64` fixture is one point of it.
- Capture: `deskbench fixture capture --from <socket> --run <id> --out crew-real.json --anonymise`: reads the thread
  pages and run metadata as the app would, replaces text with same-length generated text (headings/lists/code/tables
  kept, identifiers hashed), drops attachments' bytes, keeps timings. Stored outside the repo unless the owner says
  otherwise.

**CLI.** As above; `perfloop sweep --json` → `perfloop.sweep/1`; `explain` prints "ms/step grows 0.9 ms per agent (r² 0.98)".

**Feasibility.** Fixtures are already a seeded generator with a `FixtureSpec`; the daemon's thread route is already
the one `FixtureThread` imitates. Capture needs the owner's permission and `CAPCOMD_HOME`/socket set to the owner's
daemon, which is out of bounds for the agent: the owner runs the capture once.

**Risks.** Anonymisation that keeps lengths and structure may still leak (code blocks, URLs): hash identifiers, strip
URLs, and keep captured fixtures out of the public repo by default.

## C9. Recorded-gesture replay and a smoothness metric

**What.** Real trackpad swipes recorded once in the app, replayed into the reel's `NSScrollView` in-process (never
global), with a metric for how closely the content followed the gesture.

**Design.**
- Record: dev build, `CAPCOMD_DESK_RECORD_GESTURE=file`: `ReelView`'s scroll view subclass logs each `scrollWheel`
  event (`t`, `scrollingDeltaX/Y`, `phase`, `momentumPhase`, `hasPreciseScrollingDeltas`) and nothing else →
  `perfloop.gesture/1`.
- Replay: the existing fling path (CGEvent-built `NSEvent`s delivered to `scrollWheel(with:)`) replays the file at
  the recorded times from the run loop; AppKit's gesture handling and the reel's snapping run as in the app.
- Smoothness: per display tick, read the document layer's `presentation()` position; compute the expected position
  from the integrated deltas (the gesture's own curve); report position error (p95 pt), frames where the finger
  moved but the content did not (`stalls`), and jerk (third derivative of position, p95), all per gesture.

**CLI.** `deskbench run swipe --gesture ~/gestures/flick-left.json`; `perfloop gestures list`.

**Data.** `perfloop.gesture/1`; `StepResult.smoothness {positionErrorP95Pt, stalls, jerkP95}`.

**Feasibility.** The fling driver already synthesises phased scroll events; replay changes the source of deltas.
`CALayer.presentation()` is public. Recording needs a human hand once per gesture (an owner checkpoint).

**Risks.** The trackpad driver's momentum curve is generated by the system from the gesture, and delivered as
momentum events; replaying recorded momentum events reproduces one machine's curve, which is what we want for A/B
and not for "feel". Feel stays a human checkpoint.

## C10. A machine nobody is using

**What.** Runners (SPEC §4.2): `local` idle-gated, `ssh://` to a spare Mac, `vm` via Tart; a `queue` that runs
experiments when a runner is free.

**Design.** `perfloop queue add <exp>`; `perfloop queue run --runner ssh://mac-mini --until 07:00`. Each runner implements
`prepare(buildHash)`, `run(args) → result path`, `fetch`. The `local` runner polls `HIDIdleTime` and the frontmost
app; it starts a rep only when idle ≥ threshold and aborts the rep (marked `interrupted`, redone) on input.

**Feasibility.** `ssh` + `rsync` + the same binary. Tart: Metal paravirtualised, so the window renders (ref 14);
no nested virtualisation; CPU counters unavailable in guests (ref 15); display-link cadence in a guest unverified.

**Risks.** A VM's numbers are a different machine: the ledger keys every result by `machine.model` + runner, and
`diff`/`ab` refuse to mix runners. Idle detection on a Mac with a wake schedule is fragile; the queue logs why it
waited.

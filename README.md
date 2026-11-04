# PerfLoop

An agent-first performance loop for native macOS apps (AppKit and SwiftUI). It gives a coding agent what a person
uses Instruments for, as JSON it can read, and a loop that keeps it honest:

- **Senses.** Main-thread CPU and instructions per step; display-link frames and hitch time per second (the same at
  60 and 120 Hz); every long main-thread stretch with sampled stacks (in-process, ~1 % overhead, no profiler);
  which SwiftUI bodies ran and which state change caused them; recorded-gesture replay with a smoothness score.
- **A loop.** A candidate build against the champion in interleaved pairs: a 3-pair screen filters, a 5+5 full decides
  (Mann-Whitney, noise bands), guards the candidate can't edit veto wins that broke something (a blank row is fast),
  an append-only ledger remembers, and each experiment's `explain.txt` says what to do next.
- **Runners.** This Mac only while nobody is using it, a spare Mac over `ssh://`, an overnight queue.

The agent's view is a CLI, JSON files with versioned schemas, and the ledger (`AGENTS.md`). The design and its
history are in [`docs/design/`](docs/design/) (SPEC.md, CAPABILITIES.md, SCHEMAS.md, JOURNEY.md, TOOL.md).

## Requirements

macOS 14+, Swift 5.9+ (Xcode 15+); Apple silicon for the stack sampler (elsewhere it is off and the rest works).
Xcode's `xctrace` only for profiles. No root, no Developer Mode, no screen-recording permission.

## Quickstart: the example app

```sh
git clone https://github.com/MarvinAmador7/perfloop && cd perfloop && swift build -c release && alias perfloop=$PWD/.build/release/perfloop
cd Examples/SlowList
swift build -c release --product SlowListBench
perfloop doctor --bench .build/release/SlowListBench          # is this Mac and this bench ready?
.build/release/SlowListBench run select --reps 1               # a window for ~3 s; where the main thread's time went
./walkthrough.sh --dry-run                                      # the whole loop on it, printed
./walkthrough.sh --lock /tmp/window.lock                        # …and run (~5 min of builds, ~2 min of windows)
```

The walkthrough stores the app as the champion, screens a knob (`rows.rank=index`), refuses a cheat (rows that draw
nothing: faster, and wrong), screens, runs in full and promotes a real fix, and prints the ledger. Its numbers from
a run are in `Examples/SlowList/README.md`.

## Quickstart: your app

```sh
perfloop init --app MyApp --dir path/to/your/package      # writes Sources/MyAppBench/main.swift and PROGRAM.md,
                                                           # prints the Package.swift lines to add (--package: a
                                                           # standalone bench package instead)
# point the scenario at your app's views on fixture data, then:
swift build -c release --product MyAppBench
perfloop doctor --bench .build/release/MyAppBench
export PERFLOOP_APP=myapp
perfloop store add .build/release/MyAppBench
perfloop champion set <hash> --merged
# hand PROGRAM.md and PerfLoop's AGENTS.md to your coding agent
```

What your app adds, beside the bench target:

1. `PerfLoopProbe` on the app target, and `Probe.body("Row", id: …)` as the first statement of the bodies worth
   counting (one load of a nil when no bench is attached).
2. Optionally knobs where an idea varies: `static let layout = Knob("list.layout", default: "stack", choices: ["stack",
   "grid"])`, read as `Self.layout.value`. Defaults are what ships; a knob that wins becomes the default and is deleted.
3. Optionally `Mutations.record("Model.selection")` in the `didSet` of state that drives bodies: each stretch then says
   which change its bodies followed.

## The bench (adapter)

```swift
import PerfLoopHost

let bench = Bench(app: "myapp", stamp: perfLoopBuildStamp)          // PerfLoopStamp plugin
bench.fixture("small", params: ["items": "100"])
bench.knobs { [MyKnobs.layout] }
bench.scenario("select", summary: "Select items", guards: ["checks", "snapshot-diff"], params: ["steps": "8"]) { run in
  let model = MyModel(items: run.fixture.int("items", 100))
  try await run.show(MyListView(model: model))                     // or run.show(view: anNSView)
  for i in 0..<run.int("steps", 8) { await run.step("select#\(i)") { model.select(i) } }
  run.check("landed", model.selection == 7)
}
bench.main()
```

`run.step` runs the action and waits until the window is at rest, then records main-thread CPU, instructions,
latency (to the first frame after an `until:` condition holds), frames, stretches with stacks, bodies and causes.
`run.swipe(try run.gesture())` is a step too: a trackpad gesture (`--set gesture=synthetic:scroll-down`, or a file
recorded by hand with `BENCH record-gesture SCENARIO`) replayed into the window's scroll view with its own timestamps,
scored for how closely the content followed the fingers (position error, stalls, jerk, latency in frames). The
host answers the runner's whole contract (`ADAPTER.md`): `list`, `describe`, `run`, `snapdiff`, `knobs`, `profile`, `diff`.

## Commands

| | |
|---|---|
| `doctor [--bench PATH]` | what would make numbers untrustworthy here, and the adapter's contract, each with its fix |
| `init --app NAME [--dir D] [--package]` | scaffold a bench target and PROGRAM.md |
| `describe --bench PATH` | the adapter's manifest |
| `store add PATH` · `store import DIR --commit SHA` · `store list` · `store gc` | the content-addressed build store |
| `champion` · `champion set BUILD --merged` · `champion merged SHA` | the build to beat, and its chain back to a merged commit |
| `exp new "<hypothesis>" --bench P \| --build-cmd C --bench P \| --knobs k=v` | a candidate; screens it |
| `exp status [ID]` · `exp screen ID` · `exp full ID` · `exp promote ID` · `exp abandon ID` | the experiment verbs |
| `explain exp/ID` · `ledger` · `causes RESULT.json` | what happened, in words |
| `guards --exp ID` | the correctness guards alone |
| `session start` | the stopping rules (2 h, 20 candidates, 5 non-promising in a row) count from here |
| `sweep SCENARIO --set rows=100..5000/500` | a cost curve over a fixture parameter or knob, with a fitted slope |
| `queue add ID` · `queue list` · `queue remove QID` · `queue run --runner R` · `runner check R` · `runner clean R` | runners: `local` (idle-gated), `ssh://host` |
| `profile champion\|exp/ID [--template time\|hitches\|swiftui]` | the build under xctrace (opens a window): call trees per step, hitches, hangs, SwiftUI tables; kept in the store, never an objective |
| `diff champion exp/ID` (or two profile JSONs / traces) · `trace register` | what grew and shrank between two builds, ms per step, main thread; refuses traces of other builds |
| `gestures list` · `exp replay` | recorded and synthetic gestures; a past session as experiments |

`perfloop help` has every flag. Exit codes: 0 ok · 1 usage · 2 harness error · 6 refused (provenance, guards, owner).

## A spare Mac as the runner

Numbers from a Mac someone is using are noise; a spare Mac reached over ssh gives trusted ones. Verified on a Mac
mini (Mac16,11, macOS 26.6.2) on 4 November 2026: `perfloop runner check ssh://user@mini`, then a queued knob experiment
(`queue add ID --runner ssh://…` and `queue run --runner ssh://… --idle 60`, 2 min 13 s) and the whole SlowList
walkthrough (`./walkthrough.sh --runner ssh://…`, 34 windows), with every rep's window trusted and the champion within
±1.7 % across 11 pairs (Examples/SlowList/README.md). What that Mac needs, once:

1. **Remote Login** on, and this Mac's key in `~/.ssh/authorized_keys` there (perfloop logs in with keys only).
2. **The user logged in at the console, the screen unlocked.** A window behind the lock screen is never active: the
   runner waits while it is locked (that is correct; it is how it behaved on the mini before). For unattended nights:
   automatic login for that user, the screen lock off ("Require password after screen saver" never), display sleep
   never (`sudo pmset -a displaysleep 0 sleep 0`).
3. **Nothing else running in that session.** `runner check` lists what is busy there (`load: … busy there: …`); a VM
   helper or a browser is noise in every rep even when the window is trusted. Best: a dedicated user for the bench,
   with nothing else open.
4. The display it has decides the frame numbers: the mini drove a 60 Hz, 1× panel, so its hitch figures aren't a
   ProMotion MacBook's. Results never mix runners.

## Where things live

- The store: `${PERFLOOP_HOME:-~/.perfloop}/<app>/` (builds by sha256, experiments, `ledger.jsonl`, `champion.json`).
  Never in a repo; a project-local `.perfloop/` is gitignored.
- Traces (`.trace`) carry the recorded process's environment, tokens included: never commit or share them; the store
  records their paths only.
- Schemas: `ADAPTER.md` §8 lists every document and its version.

## The package

| Product | Linked by | |
|---|---|---|
| `PerfLoopProbe` | the app | knobs, the body/event probe, mutation records, gesture recording. Foundation only |
| `PerfLoopHost` | the app's bench | window, display link, stretch clock, sampler, counters, snapshots, the result, the CLI contract. macOS |
| `PerfLoopKit` | the runner and the host | schemas, statistics, acceptance, stacks, explain. Builds and tests on Linux |
| `perfloop` | you and your agent | the runner (`PerfLoopRunner`) |
| `PerfLoopStamp` (plugin) | the bench target | the commit, dirty flag and build time compiled in |

Tests: `swift test` (no window: fake adapters, fake ssh, fake idle readings). `scripts/check-imports.sh` keeps the
package free of any app's modules. `Examples/SlowList` has its own `swift test`.

## Status

Built and used on [capcomd](https://github.com/MarvinAmador7/capcomd) Desktop (adapter `deskbench`, where PerfLoop started) and on `Examples/SlowList`. Not yet in
PerfLoopHost: xctrace profiles and `diff` (deskbench has them), gesture replay drivers, the VM runner. See
[`docs/design/TOOL.md`](docs/design/TOOL.md) for what's left.

## License

MIT. See [LICENSE](LICENSE).

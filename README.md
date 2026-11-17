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
./walkthrough.sh                                                # …and run (~5 min of builds, ~2 min of windows)
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
perfloop champion set <hash> --merged                     # you, the owner: it asks you to type yes (§ The owner's flags)
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
| `store add PATH` · `store import DIR --commit SHA` · `store list` · `store gc [--traces]` | the content-addressed build store; gc also deletes `.trace` bundles left in it |
| `champion` · `champion set BUILD --merged` · `champion merged SHA [--main REF]` | the build to beat, and its chain back to a merged commit. `set` is the owner's (the owner flags' gate); `merged` is checked in the app's checkout: SHA must be on main (`origin/main`, else `main`, or `--main REF`) and contain the champion's build commit |
| `exp new "<hypothesis>" --bench P \| --build-cmd C --bench P \| --knobs k=v` | a candidate; screens it |
| `exp status [ID]` · `exp screen ID` · `exp full ID` · `exp promote ID` · `exp abandon ID` | the experiment verbs |
| `explain exp/ID` · `ledger` · `causes RESULT.json` | what happened, in words |
| `suggest [champion\|exp/ID\|RESULT.json]` | ranked hypotheses for the next experiment from the cause records, stacks, profile and sweep, each with its evidence and the share it could remove (leads, not conclusions) |
| `guards --exp ID` | the correctness guards alone |
| `session start` | the stopping rules (2 h, 20 candidates, 5 non-promising in a row) count from here |
| `sweep SCENARIO --set rows=100..5000/500 [--budget-ms X]` | a cost curve over a fixture parameter or knob, with a fitted slope and where it crosses the frame (or your) budget: inside the measured range, extrapolated ×k, or not claimed past 4× |
| `queue add ID` · `queue list` · `queue remove QID` · `queue run --runner R` · `runner check R` · `runner clean R` | runners: `local` (idle-gated), `ssh://host` |
| `mcp [--app NAME]` | the loop as MCP tools for a coding agent, stages as jobs (§ Agents over MCP) |
| `profile champion\|exp/ID [--template time\|hitches\|swiftui]` | the build under xctrace (opens a window): call trees per step, hitches, hangs, SwiftUI tables; kept in the store, never an objective. The trace is deleted afterwards (checked on disk) unless `--keep-trace` |
| `lock -- CMD` · `lock` | run CMD holding the window lock (for windows outside perfloop's verbs); who holds it now |
| `diff champion exp/ID` (or two profile JSONs / traces) · `trace register` | what grew and shrank between two builds, ms per step, main thread; refuses traces of other builds |
| `gestures list` · `exp replay` | recorded and synthetic gestures; a past session as experiments |

`perfloop help` has every flag. Exit codes: 0 ok · 1 usage · 2 harness error · 6 refused (provenance, guards, owner).

On this Mac, every windowed verb waits while the screen is locked, before taking the window lock (`--no-wait`: stop
instead), with or without `--idle`; then, holding the lock, it waits up to `--quiet-timeout` (60 s) for a quiet
machine: at most `--max-load` (30) % of the cores busy and no compiler, linker or test run going. A rep that started
busy anyway is recorded as `"quiet": false` on its side of the pair, with the busiest processes, and is untrusted
(`--require-quiet`: stop instead). A rep that drew no frames has no frame metrics and is untrusted too. On other
runners the quiet gate reads the machine whose load distorts the reps, never this one: an `ssh://` runner's remote Mac
(`iostat` and `ps` there), a `vm:` runner's host (this Mac: the guest's own load misses the host's contention). Same
flags, same thresholds.

### The owner's flags

`--force` (a full over a rejected screen, or `queue run` without the idle gate), `--owner` (decide what waits for the
owner), `--guard-tolerance` (loosen a guard) and `--allow-dirty` (promote a dirty build) override what judges the
agent, so they are yours, never your agent's. So are two commands: `champion set` (it picks the build every later
verdict is judged against: you set the first champion, and reset it) and `exp replay --go` (it sets the plan's
champion). The CLI honours one only when the shell shows it is yours: `PERFLOOP_OWNER=1` in the environment (scripts),
or a yes typed at the prompt when stdin and stderr are a terminal. That is the whole confirmation: no Touch ID, no
password. Anything else is refused (exit 6) with what the agent should do instead, and the refusal never names a way
around it. `champion merged SHA` is not gated: it is checked (SHA on main, containing the champion's build commit).

This is a speed bump and a record, not security. An agent's shell usually has no terminal, so it never sees the
prompt, but it can set an environment variable like anyone else. What makes a use visible is the record: every
experiment an owner flag changed gets `forced: true` and `ownerFlags` (which flag, `env` or `tty`, the command, what it
changed) in its `experiment.json`; its ledger lines carry `ownerFlags`/`ownerVia`; and the verdict, `explain`,
`exp status` and `ledger` print `FORCED (owner flag)` / `OWNER FLAG --force (PERFLOOP_OWNER=1)`. A `champion set` is
recorded the same way on its baseline experiment and ledger line (`OWNER FLAG champion set`), and in `champion.json`
(`setBy`, which `perfloop champion` prints). Look for them in an agent's PR. Don't export `PERFLOOP_OWNER` in a shell profile your agents inherit: set it per command.

## Agents over MCP

`perfloop mcp` serves the loop as Model Context Protocol tools over stdio, for any agent that speaks MCP:

```sh
claude mcp add perfloop -- /path/to/perfloop mcp --app myapp          # Claude Code
# Codex (~/.codex/config.toml):  [mcp_servers.perfloop]  command = "/path/to/perfloop"  args = ["mcp", "--app", "myapp"]
```

The tools are the agent's verbs (`status`, `explain`, `suggest`, `new_experiment`, `screen`, `full`, `promote`,
`profile`, `diff`, `sweep`, …) with their schemas. A stage that builds or opens windows returns a job at once; `job`
waits for it on the server's side (up to 60 s a call), so the agent never writes a sleep loop, and every job still
running when the session ends is killed with its windows. Local runs hold the window lock (§ The window lock;
`mcp --lock DIR` moves it). The owner's flags (`--force`, `--owner`, `--guard-tolerance`, `--allow-dirty`) are no tool's
arguments, no tool sets, merges or replays the champion (`champion` only reads it), no value may start with `-`, and the CLI children never see `PERFLOOP_OWNER`. Job logs are in the store's `jobs/`. The shell CLI stays the reference;
the server runs it for every call.

## The window lock

Two bench windows on one Mac spoil each other's numbers, so window runs take turns at one lock, on by default: every
perfloop verb that opens a window here (`exp new`/`screen`/`full`, `guards`, `profile`, `sweep`, `exp replay --go`,
`queue run --runner local`) holds it around each rep, the MCP server's jobs too, and a PerfLoopHost bench's `run`,
`profile` and `record-gesture` hold it for their whole run when started by hand. `perfloop lock -- CMD` holds it around
anything else (an adapter's own `ab`, a script). It lives at `$PERFLOOP_LOCK`, else `/tmp/perfloop-window-UID.lock`
(not `$TMPDIR`, which agents' sandboxes give each their own); `--lock DIR` takes another, `--no-lock` (or
`PERFLOOP_LOCK=off`) none, for a Mac no other bench uses.

It is a directory (mkdir is atomic) whose `owner` file says who holds it: `{"pid", "command", "label", "since"}`, the
label from `PERFLOOP_LOCK_OWNER` or `perfloop lock --label`. A waiter prints the holder once and again when it changes;
`perfloop lock` (and `doctor`) say who holds it now. A lock whose holder died (its pid gone, or reused since) is broken
by the next taker, and ^C or a kill releases it. A holder exports `PERFLOOP_LOCK_HELD` to its children, so a bench run by
perfloop, or perfloop run by `perfloop lock --`, doesn't wait for its own parent (ADAPTER.md §6b).

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

## A macOS VM as the runner

`--runner vm:tart/NAME` boots a Tart VM on this Mac headless, finds its address, installs a key of its own in the guest
once (with the image's password: `PERFLOOP_VM_USER`/`PERFLOOP_VM_PASSWORD`, admin/admin in Cirrus Labs' images), waits
for its automatic login, runs the windows there, and stops the VM it booted. Verified on 4 November 2026 with
`ghcr.io/cirruslabs/macos-tahoe-vanilla` (macOS 26.6.2 guest, 4 vCPUs, 8 GB, 24 GB to download, 26 GB on disk) on a
MacBook Pro M1 Pro: `runner check` in 22 s from cold, and a SlowList knob screen with 3 of 3 pairs trusted (champion
93.8–115.5 ms, candidate 15.5–17.3 ms, band ±11 %, against ±5 % on the mini). As SPEC §4.2 expected, the guest reads no
instruction counts and runs at 60 Hz, so a VM screens and never decides a full (`exp full` refuses it). Needs Tart
(`brew install cirruslabs/cli/tart`, or `PERFLOOP_TART=PATH`; its licence is free for personal use and small
organisations) and an image: `tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest NAME`.

## Where things live

- The store: `${PERFLOOP_HOME:-~/.perfloop}/<app>/` (builds by sha256, experiments, `ledger.jsonl`, `champion.json`).
  Never in a repo; a project-local `.perfloop/` is gitignored.
- Traces (`.trace`) carry the recorded process's environment, tokens included: never commit or share them; the store
  records their paths only. `perfloop profile` deletes each once exported and checks it is gone (`--keep-trace` keeps
  it, and says where); `perfloop doctor` fails on one left in the store (and warns on a kept one), and `perfloop store
  gc` deletes those (`--traces`: the kept ones too). The recorded process gets a scrubbed environment, so a kept trace
  carries no tokens: only `HOME`, `USER`, `LOGNAME`, `PATH`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`, `TERM`, `TZ`,
  `__CF_USER_TEXT_ENCODING`, `DEVELOPER_DIR`, the bench's own `PERFLOOP_` variables (knobs, guards, artifacts, store,
  window lock, sampler; never `PERFLOOP_OWNER`) and what the adapter's manifest declares in `profileEnv`. A name that
  looks like a secret (`TOKEN`, `SECRET`, `KEY`, `PASSWORD`, `AUTH`, `SESSION`, `COOKIE`, `CREDENTIAL`, …) never
  passes, declared or not.
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

Built and used on [capcomd](https://github.com/MarvinAmador7/capcomd) Desktop (adapter `deskbench`, where PerfLoop
started) and on `Examples/SlowList`. PerfLoopHost now has what deskbench had beyond the loop itself: xctrace profiles
and `diff` per step, gesture replay with the smoothness meter, and a recorder for a real hand. Runners: this Mac
(idle-gated), a spare Mac over ssh (verified on a Mac mini, trusted runs), a macOS VM with Tart (`vm:tart/NAME`, screens
only). For agents: `perfloop mcp` and `perfloop suggest` (docs/BEYOND.md says why and what not to claim).

Still open: deskbench itself moving onto PerfLoopHost (capcomd's side); a gesture recorded by a real hand (the recorder is
built and was checked by feeding it a synthetic gesture; feel stays the owner's call); the design history in
[`docs/design/`](docs/design/) is kept as it was, so TOOL.md's G8 line is now out of date.

## License

MIT. See [LICENSE](LICENSE).

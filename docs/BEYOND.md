# Beyond conventional tooling

What Instruments, XCTest performance tests and MetricKit can't do for a coding agent that works on a Mac app alone, and
which capabilities would make PerfLoop clearly better at that job. Each idea is tied to something that went wrong in
[JOURNEY.md](design/JOURNEY.md) or in the runs of 4 November 2026 (this file's own runs, in the repository's history).
They are ranked by their value to one developer with a coding agent. The top three are built (§4).

## 1. What the conventional tools give, and where they stop

| Tool | What it is good at | Where it stops for an unattended agent |
|---|---|---|
| **Instruments** (`xctrace record/export`) | Every sense there is: time profile, hitches, hangs, allocations, SwiftUI cause and effect, energy, with system-wide context | One recording is one run, with no noise model, so a 10 % difference between two recordings means nothing on its own. Comparing two recordings is left to you (`xctrace export` prints XML tables; the 30 October session wrote a Python parser on the spot). The profiler's cost lands in the numbers (`dtsecurity` at 172 % during the only run with stacks, JOURNEY §2 and SPEC §1). It can't say whether a faster build is still correct. And traces carry the recorded process's environment, tokens included. |
| **XCTest performance tests** (`measure(metrics:)`: clock, CPU with instructions retired, memory, storage, signposts, launch) | Repeatable measurement in a test target, baselines in Xcode, pass/fail against a baseline's standard deviation | One build per run, with no interleaved A vs B and no significance test: a baseline is a stored average per device. No "where did the time go" and no causes. The test owns the app it measures, so a change that makes the measured path do less passes (a blank row is fast). Results live in `.xcresult` bundles and `xcbaselines`, made for Xcode's UI rather than for an agent's next step. |
| **MetricKit** (`MXMetricManager`) | Real users' launch time, hangs, CPU, memory, disk and energy, from the field, by app version | It arrives a day later, aggregated per version: it can't tell a candidate from a champion, and an agent can't run it in a loop. It confirms after shipping; it doesn't drive changes before. |

What PerfLoop already adds on top (README): interleaved pairs with noise bands and Mann-Whitney; guards the candidate
can't edit; stacks and causes in every run without a profiler; a ledger; idle-gated and remote runners. Since this
branch it also has xctrace profiles and `diff` per step for any app, and replayed gestures with a smoothness score.
The question here is what would make it *clearly* better for an agent, not just an automated Instruments.

## 2. Failure modes the candidates answer

| # | What went wrong | Where | What it asks for |
|---|---|---|---|
| F1 | Agents driving long jobs from a shell left wait loops running for hours (`pgrep -f` matched itself and they never ended); a `full` takes 3 min, a queue all night | capcomd's agent sessions (AGENTS.md "Never leave processes behind" exists because of it) | jobs the agent starts and then asks about, owned by something that cleans up |
| F2 | The flags that change how a candidate is judged (`--force`, `--owner`, `--guard-tolerance`, `--allow-dirty`) are in the same CLI the agent drives; only prose (AGENTS.md "Never") keeps the agent off them | AGENTS.md; SPEC §5.4–5.5 (anti-Goodhart) | an agent surface where those flags don't exist |
| F3 | The data had the answer before anyone acted on it: "every column body ran twice per update" was in the cause records for days before an agent tied it to the two-window bench bug; the profile split said "number of views, not layout math" after a Rust layout engine had been considered | JOURNEY §5.4, §5.5 | the records read for the agent as candidate hypotheses, each with its evidence |
| F4 | An idea was picked by intuition and lost: of the native-path round's knobs, one was promising and four were slower (+16 % to +778 %) | JOURNEY §5.5 | the same as F3: start from the largest attributable cost |
| F5 | Cost curves were measured but read by eye: 3.28 ms per agent, 50 → 261 ms from 4 to 64 agents; SlowList 0.07 ms per row. Nobody wrote down at which size the frame budget breaks | JOURNEY §5.5; Examples/SlowList README | the sweep saying where the budget is crossed, and how far that is extrapolated |
| F6 | Numbers didn't transfer between machines: SlowList's `select` was 86.5–89.6 ms on the MacBook Pro in use and 64.8–66.8 ms on the Mac mini (the same build); the dev Mac's runs were untrusted | JOURNEY §5.1, §7; this branch's mini run | results that say what they would be elsewhere, or at least never mix (they don't) |
| F7 | A replayed flick moved SlowList's content 138 pt on the slow path's first swipe and 873 pt with the fix, for the same 566 pt of deltas; the smoothness meter (fingers-down error) scored both 0 pt | this branch's `scroll` runs | a sense for what the content did after the fingers lifted: travel and deceleration against the gesture |
| F8 | Nothing watches `main` between sessions: a regression lands unnoticed until the next by-hand session, and the 30 October numbers had to be re-measured after a bench fix | JOURNEY §2, §5.4, §9 item 4 | a per-commit check on a trusted runner |
| F9 | Work the app does while nobody touches it (a display link left running, a timer) costs battery on a Mac and is invisible to step-based scenarios | not seen yet on these apps: a gap, not an incident | an "at rest" sense: CPU and wakeups with the window idle |

## 3. The candidates, ranked

Value is to one Mac developer whose coding agent runs the loop; cost is to build it here. "Instruments can't" is
checked against §1.

| Rank | Capability | Answers | Value | Cost | Built |
|---:|---|---|---|---|---|
| 1 | **An MCP server (`perfloop mcp`)**: the loop as tools with schemas any MCP agent discovers (Claude Code, Codex, Cursor); long stages run as jobs the agent starts and then asks about (`job` waits on the server's side, up to 60 s a call), killed when the session ends; the owner's flags aren't tools at all | F1, F2 | High: it removes both failure modes structurally, and the agent sees the procedure (tool descriptions) without reading AGENTS.md first | Medium | **yes** |
| 2 | **`perfloop suggest`**: ranked hypotheses from what a run already records (cause fan-out: bodies × views per mutation; the same body twice per id in one update; hot app frames and the framework work under them; a profile's largest app subtrees; a sweep's slope), each with its evidence and the share of the objective it could remove | F3, F4 | High: it is the step between "here is the data" and "here is the next experiment", and the step agents (and people) skipped | Low–medium (rules over existing records) | **yes** |
| 3 | **The budget wall from a sweep**: where a fitted cost curve crosses a budget (the frame at 120/60 Hz, or the scenario's latency budget), with how far beyond the measured points that is | F5 | Medium-high: it warns before an app hits the wall, from data PerfLoop already has; no other tool fits a curve across builds or sizes | Low | **yes** |
| 4 | **Regression watch per commit**: `perfloop watch` on a trusted runner (the mini), champion vs each new `main` commit, screen only, a line per commit in the ledger and an exit code for CI | F8 | High for a team; medium for one developer (the loop already compares every candidate) | Medium (needs a self-hosted runner and CI wiring: the owner's) | no |
| 5 | **Content travel after release**: the meter also reports how far the content went against the delivered deltas, and how deceleration ended (snap, overshoot) | F7 | Medium: feel is the owner's call, but "the content stopped short" is a measurable defect | Low–medium | no (F7 needs a real recorded gesture first: the replayed momentum may not be how AppKit treats a hand's) |
| 6 | **At rest**: CPU ms and wakeups per second with the window idle after the steps (`proc_pid_rusage` interrupt and idle wakeups) | F9 | Medium for battery-sensitive apps | Low | no |
| 7 | **Memory per step and growth across reps** (`phys_footprint`) | none seen | Medium-low: XCTest's memory metric covers much of it | Low | no |
| 8 | **Cross-machine comparability**: a per-machine factor from a calibration scenario, so a mini number predicts a MacBook number | F6 | Low until there is a second trusted machine; the ledger already refuses to mix machines, which is the safe answer | High (and easy to get wrong) | no |
| 9 | Launch time | none seen | Low: `XCTApplicationLaunchMetric` and MetricKit cover it | Low | no |

## 4. What was built

- **`perfloop mcp`** (`Sources/PerfLoopRunner/MCPServer.swift`): MCP over stdio (JSON-RPC 2.0, newline-delimited).
  Read-only tools (`status`, `explain`, `ledger`, `champion`, `doctor`, `describe`, `suggest`, `gestures`) answer at
  once. Window-opening stages (`new_experiment` with its screen, `screen`, `full`, `profile`, `guards`, `sweep`) start a
  job: the server runs the CLI as its child, keeps its output in the store (`jobs/<id>.log`), and kills every job that
  is still running when the session ends. The `job` tool waits on the server's side, up to 60 s a call, so an agent
  never needs a sleep loop. `promote` and `abandon` act as the agent. No tool takes `--force`, `--owner`,
  `--guard-tolerance` or `--allow-dirty`. Setup: README → "Agents over MCP".
- **`perfloop suggest`** (`Sources/PerfLoopKit/Suggest.swift`, `perfloop.suggest/1`): reads the champion's (or an
  experiment's) latest results, its newest profile and the store's sweeps, and prints hypotheses ranked by the share of
  the objective each could remove, with the evidence. They are leads, not conclusions: each says what to check first.
  It is also in every experiment's `explain.txt`.
- **Budget walls** (`Sweep.walls`, in `perfloop.sweep/1` as `walls`): the size at which each fitted curve crosses the
  frame budget at the measured refresh rate (or `--budget-ms`), marked `extrapolated` with the factor beyond the
  largest measured point, and refused as a claim past 4× (`beyond`).

Each has tests and an entry in the README. What not to claim: no agent has yet run a full session through the MCP server
on capcomd; `suggest`'s rules were written from two apps (capcomd's records in JOURNEY and SlowList), so they will miss
causes neither had; a wall is a line through a few points, not a prediction of the app's future.

# Driving PerfLoop (for coding agents)

You are a coding agent (Claude Code, Codex, …) asked to make a native macOS app faster with PerfLoop. This file is the
rules; the app's `PROGRAM.md` (written by `perfloop init`, then edited by its owner) is the procedure for that app:
its bench, scenarios and budgets. Copy this file next to it, or load it as a skill. If the two disagree, PROGRAM.md and
the owner win.

## What PerfLoop is, in one paragraph

The app has a **bench**: an executable that shows the app's real views on fixture data and measures scenarios (what
a user does) in a window of its own. `perfloop` keeps a **champion** build and judges each **candidate** against it in
interleaved pairs: a 3-pair **screen** filters, a 5+5 **full** decides (Mann-Whitney, noise bands), and **guards** the
candidate can't edit veto any win that broke something. Every state change lands in an append-only **ledger**; each
experiment's `explain.txt` says what happened and what to do next. You change code; the loop decides.

## The loop

```sh
perfloop session start                       # the stopping rules count from here
perfloop exp status                          # what is open, what each needs next, and a `stop:` line when it's time
perfloop explain exp/<id>                    # where the time went; the last line is the next command
perfloop suggest                             # hypotheses from what was recorded, ranked, each with its evidence
# one idea → edit the app → commit →
perfloop exp new "<one-sentence hypothesis>" --build-cmd "<build>" --bench <bench path>
perfloop exp new "<hypothesis>" --knobs name=value          # an idea the app already has as a knob: no rebuild
perfloop exp full <id>                       # when the screen says promising
perfloop exp promote <id>                    # when the full says won; then a PR with explain.txt and the patch
perfloop ledger                              # what was tried, by whom, with what result
```

1. **Look before you change.** Read the champion's explain: the worst stretch, the app frames (`ours`), the framework
   frames and the app frame they ran `under`, the bodies (`Row×15`) and the state changes they followed (`causes`).
   Pick the largest cost that is yours or attributable to one of your frames.
2. **One idea per experiment**, said in one sentence that names the cost and why the change removes it. Two ideas in
   one build teach nothing when it loses.
3. **Commit before `exp new`.** The bench is stamped with its commit; promotion refuses a dirty build.
4. **Read the verdict, don't argue with it.** `rejected`: drop the change (reset your work branch) and go back to 1;
   if you think the screen was borderline, say so in your report with its numbers and let the owner decide (there is
   no way for you to get a full on it). `promising`: run the full. `won`: promote and open a PR. `lost`: drop it.
   `needsReview`: stop and ask the owner.
5. **Stop** when `exp status` prints `stop:` (the budget is met, no cost ≥ 5 % of the objective is left that you can
   attribute, 5 non-promising candidates in a row, or 2 h / 20 candidates spent), and report from the ledger: what you
   tried, what won, what's left.

## Never

- **Never edit what judges you**: the bench target (scenarios, fixtures, guards, checks), the manifest, PROGRAM.md, the
  store (`~/.perfloop`), the PerfLoop package itself. The runner reads the rules from the *champion's* manifest, so a candidate
  that changes them is judged by the old ones anyway; changes to the bench are their own PR for the owner.
- **Never make the app aware of the bench**: no `PERFLOOP_` checks outside knobs, no fixture names, no "if measured"
  branches. A blank row that is fast is still a blank row; the guards exist because the search will find it.
- **Never pass `--guard-tolerance`, `--owner`, `--force` or `--allow-dirty`, and never set `PERFLOOP_OWNER`.** They
  exist for the owner: the CLI refuses them (exit 6) unless `PERFLOOP_OWNER=1` is set or someone types yes at a
  terminal, and a refusal means stop and do what it says, not find another way. If the owner wants one used, they run
  it themselves. Every use is recorded in the experiment, the ledger and `explain` (`FORCED (owner flag)`); if one
  was used on your experiments, your PR says so.
- **Never commit or publish `.trace` files**, stores, results with paths from someone's home, or anything with
  secrets. xctrace traces embed the recorded process's environment (tokens included). `exp new` refuses a patch that
  touches a `.trace` or a path the manifest lists in `privatePaths`.
- **Never send synthetic input to the system** or click around the owner's Mac. Benches drive the app in-process.
- **Never leave processes behind**: no wait loops, watchers or benches running when you stop (`ps` to check; note that
  `pgrep -f` matches itself).

## The machine

`exp new` (it screens), `exp screen`, `exp full`, `guards`, `profile`, `sweep` and a bench's `run`/`ab` open a window
and take focus for seconds to minutes. Run them only when the owner says the Mac is free, or queue them: `perfloop queue
add <id>` and let `perfloop queue run --runner local --idle 120` (only while nobody touches the Mac) or
`--runner ssh://user@spare-mac` (a Mac nobody uses) take them.

**The window lock** makes window runs on one Mac take turns, and it is on by default: every perfloop verb above holds it
around each rep, as do the MCP server's jobs and a PerfLoopHost bench's `run`/`profile`. Anything else that opens a
window (a bench's own `ab` or `run` from an adapter that isn't PerfLoopHost, a script driving the app) goes inside it:
`perfloop lock -- <command>`. Set `PERFLOOP_LOCK_OWNER=<your name>` so others see who waits on whom. A waiter prints
the holder (`waiting: the window lock /tmp/perfloop-window-501.lock is held by pid 71104 (perfloop exp screen 0003)
"palette", since …`); `perfloop lock` alone says who holds it now. A holder that died is broken by the next taker; never
remove a live holder's lock, and never make one by hand with `mkdir` (it says nobody's name and is never broken).

A run on a locked screen, in the background, on a busy Mac or under a profiler is **untrusted** and never decides: a
stage that needed it says `UNTRUSTED` with how many reps and why, and is neither rejected nor lost. Rerun it when the
Mac is quiet (only the untrusted pairs run again), don't explain it away; when its `next:` says a rerun won't help (one
side's window is wrong the same way every time), do what it says instead. `perfloop doctor` says what would make this
Mac's numbers untrustworthy.

Local runs avoid both where they can. They never start a rep on a locked screen: the runner waits for the unlock
before taking the window lock (`--no-wait` stops instead; finished pairs are kept), and a rep during which the screen
locks is redone. A rep that presented no frames anyway has no frame metrics (never a perfect 0) and is untrusted:
`no frames (screen locked or window off-screen)`. Before each rep, holding the window lock, the runner waits up to
60 s (`--quiet-timeout S`) for a quiet machine: at most 30 % of the cores busy (`--max-load PCT`) and no build or test
run going. Then the rep runs anyway and is untrusted (`"quiet": false` on its side of the pair, `busy` naming what was
busy, the gate's wait under `machine`); `--require-quiet` stops instead. So don't build or test while a stage runs,
and read `waiting … for a quiet machine: building: swift-frontend` as "my own build is the noise".

Over MCP (`perfloop mcp`), the same verbs are tools: a stage returns a job, and `job` waits for it on the server's side,
so never poll with `sleep`; the session's end stops its jobs.

Headless and always fine: `doctor`, `describe`, `store list`, `exp status`, `explain`, `ledger`, `champion`, `causes`.

Disk: every build in the store is a copy of the bench (`perfloop store gc` keeps the newest 20 and every champion);
traces are hundreds of MB. Delete what you made once its numbers are recorded.

Traces: `perfloop profile` deletes the `.trace` once exported and its `trace:` line says what is on disk: `deleted`, or
`KEPT at <path>` (`--keep-trace`, or a delete that failed: the notes say why). A kept trace holds the recorded process's
environment, tokens included: delete it once read (`perfloop store gc --traces`). `perfloop doctor` fails while a stray
one is in the store; `perfloop store gc` deletes those.

## Ask the owner

- Any change in behaviour (what the user sees or can do): declare it with `--behaviour-change`; promotion then needs
  the owner.
- Feel and taste: animation curves, springs, gesture handling, spacing, what a placeholder shows. The bench measures
  smoothness, not feel.
- A `needsReview` verdict: a snapshot that doesn't look like the champion's (both pictures and a diff are in the
  experiment's folder), or no decision at 10+10 pairs.
- A guard, scenario or fixture you think is wrong or missing.
- Promoting a knob: the winning value becomes the default and the knob is deleted, in a follow-up change.

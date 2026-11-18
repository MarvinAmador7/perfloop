# Driving PerfLoop (for coding agents)

You are a coding agent (Claude Code, Codex, …) asked to make a native macOS app faster with PerfLoop. This file is the
rules; the app's `PROGRAM.md` (written by `perfloop init`, then edited by its owner) is the procedure for that app:
its bench, scenarios and budgets. Copy this file next to it, or load it as a skill. If the two disagree, PROGRAM.md and
the owner win.

Verifying a feature rather than making it faster (it works, it's drawn, it answers input, it costs nothing)? Read
[docs/VERIFICATION.md](docs/VERIFICATION.md) for the verbs and verdicts, which of them exist yet, and what your PR's
evidence should say. A feature's own scenarios run through `perfloop run` (below), never the bench by hand; anything
else that opens a window goes inside `perfloop lock -- …`, and your PR says its numbers are outside the ledger.

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
perfloop exp screen <id> --more 3            # when the screen says inconclusive: 3 more pairs, judged with the first
perfloop exp full <id>                       # when the screen says promising (or inconclusive)
perfloop exp promote <id>                    # when the full says won; then a PR with explain.txt and the patch
perfloop champion merged <sha>               # once that PR is on main (git fetch first): checked, from the app's checkout
perfloop ledger                              # what was tried, by whom, with what result
```

1. **Look before you change.** Read the champion's explain: the worst stretch, the app frames (`ours`), the framework
   frames and the app frame they ran `under`, the bodies (`Row×15`) and the state changes they followed (`causes`).
   Pick the largest cost that is yours or attributable to one of your frames.
2. **One idea per experiment**, said in one sentence that names the cost and why the change removes it. Two ideas in
   one build teach nothing when it loses.
3. **Commit before `exp new`.** The bench is stamped with its commit; promotion refuses a dirty build.
4. **Read the verdict, don't argue with it.** `rejected` (slower in every pair, a guard failed, or the gain can't
   reach 5 % even at best): drop the change (reset your work branch) and go back to 1; there is no way for you to get
   a full on it, so if you dispute it, say so in your report with its numbers and let the owner decide.
   `inconclusive` (mixed signs, or a band wider than the gain: three pairs can't tell): add pairs with
   `exp screen <id> --more 3` (cheaper; it then needs as many pairs won as a 3-pair screen's evidence, e.g. 5 of 6) or
   run the full, which decides; never drop it on that screen alone. `promising`: run the full. `won`: promote and open
   a PR. `lost`: drop it. `needsReview`: stop and ask the owner.
5. **Stop** when `exp status` prints `stop:` (the budget is met, no cost ≥ 5 % of the objective is left that you can
   attribute, 5 non-promising candidates in a row, or 2 h / 20 candidates spent), and report from the ledger: what you
   tried, what won, what's left. The 2 h run from your first optimisation experiment, not `session start`, and stop
   while an expect-same stage runs; `exp status` says how much is spent and left (`time budget: 34 of 120 min spent,
   86 min left (…)`, `timeBudget` in its `--json`).

## A feature PR: show it costs nothing (`--expect same`)

When your change adds or alters a feature rather than making something faster, the question isn't "is it faster" but
"does it cost anything". Ask that one:

```sh
perfloop exp new "the sidebar toggle" --build-cmd "<build>" --bench <bench path> --expect same [--scenario S]
perfloop exp screen <id> --more 3            # when it says inconclusive; or perfloop exp full <id> (up to 10 + 10)
```

It measures the same interleaved pairs, guards and trust rules, and answers in a feature PR's terms:

- `noRegression`: it costs nothing measurable. The verdict line says how much at most (`change +0.4 % (90 % interval
  -0.8 % … +1.6 %, margin 5 %)`): quote it in the PR. Nothing to promote: these experiments never move the champion.
- `regressed`: a guard failed, or it is slower (or hitches more) beyond the margin, by at least the interval's low
  end. `next:` says by how much on which metric and where to look (the worst stretch, `profile`, `diff`). Fix it and
  check the new build with a new `--expect same` experiment; a regression is the feature's to fix, not a reason to drop
  it.
- `inconclusive`: this Mac's noise is wider than the margin: add pairs (`--more`, then the full). Still inconclusive at
  10 + 10: say exactly that in the PR, with the numbers, or check again on a quieter runner.

The margin is the smallest change worth calling for the metric (5 % of CPU per step, 15 % or 3 ms of latency, 25 % of
a frame metric), never the run's noise, so a noisy Mac makes it say "can't tell", not "costs nothing". It runs on the
scenarios the champion's manifest has; a snapshot that differs from the champion's is listed as a `look:` for the PR,
not a verdict (a feature changes what it shows). These checks get no "drop it", and count toward none of the stopping
rules (the streak, the 2 h, the 20 candidates): the 2 h clock starts at the first optimisation experiment and doesn't
run while an expect-same screen or full does.

## Measuring without a verdict: `run` and `baseline`

`exp` judges a candidate against the champion, on a scenario the champion has. Two things it can't do, and what to use
instead of running the bench by hand (a bench run by hand skips the gates, the window lock and the ledger):

```sh
perfloop run <champion|exp/ID|BUILD|BENCH> --scenario S [--fixture F] [--reps N] [--reference S2]   # numbers, no verdict
perfloop baseline S --bench PATH [--reference S2]   # first numbers + a reference snapshot for a scenario the champion lacks
```

- **Use `exp`** when the question is "is this change faster (or not worse) than the champion?" and the champion has
  the scenario. Only `exp` decides anything.
- **Use `run`** to measure one build: your feature's own new scenario (one only your branch's bench has, which `exp new`
  refuses), a fixture you're checking, how a build behaves before you form a hypothesis. It runs the build's own
  scenario and checks through the same runner as a stage (screen-lock wait, quiet gate, window lock), one child per rep,
  stores `runs/<id>/` and a ledger line `measure` (`baseline` writes `baseline`), and prints the trusted reps' numbers, the checks and where the time
  went. Exit 3: the scenario's own checks failed (fix the feature first); exit 5: no rep could be trusted.
- **Use `baseline`** once, in the feature's PR, for each new scenario: it records first numbers (trusted reps only) and
  the window's picture. After the merge, when the champion has the scenario, `exp status` says so and `perfloop run
  champion --scenario S` is compared with the baseline (numbers and picture). Quote the baseline in the PR.
- **`--reference S2`** runs a champion scenario beside each rep, in the same minutes, so a reader can tell a slow
  feature from a slow Mac ("this Mac runs 12 % slower than at the champion's full"). Use one whenever the Mac is shared.
- **A check must pass in every trusted rep.** One that passes in some is `flaky 2/3`, and a failure (exit 3 for `run`,
  a veto in `exp`): it races something, usually the first commit after a structural change. Fix the check (ADAPTER.md
  §3b: `until:`, `wait`, `settle`), never rerun until it passes.
- **Look at the pictures.** The built-in ink guard (a scenario's `run.step(…, ink: [regions])`) leaves a crop of every
  region it judged; `run` and `explain` print `look at (ink…): PATH`. Open them: a region can pass with the wrong content.
- **The bench measuring itself** shows as `warning: N % of the worst stretch … is the bench's own code`: move the check
  out of the step (`await run.check(name) { … }` or the ink guard run off the clock) before reading the step's numbers.
- **Untrusted reps are named, never quoted.** A `run` whose reps were all untrusted prints `UNTRUSTED` and no number;
  rerun it when the Mac is quiet, and never copy an untrusted rep's value into a PR. `baseline` records nothing then.
- **`file:` fixtures** (`--fixture file:PATH`, when your adapter takes them): the file must be on the Mac the reps run
  on. perfloop asks that Mac (an `ssh://` runner too: it copies builds there, never fixture files) and refuses the
  fixture before anything is built or run; each stage asks again on its own runner. Locally a relative path is read
  from the directory perfloop runs in; on a remote runner give an absolute path. perfloop never copies the file to an
  `ssh://` runner: when it is refused there, copy it there yourself (e.g. rsync) and run the same command again.
  `sweep` takes no `file:` fixture at all, only the manifest's, so a sweep can be run again from the bench alone.
- A `run` or a baseline is information, not a verdict: different minutes, no interleaving with the champion. "No
  regression" claims need an `exp` (`exp new … --expect same`, above).

## Never

- **Never edit what judges you**: the bench target (scenarios, fixtures, guards, checks), the manifest, PROGRAM.md, the
  store (`~/.perfloop`), the PerfLoop package itself. The runner reads the rules from the *champion's* manifest, so a candidate
  that changes them is judged by the old ones anyway; changes to the bench are their own PR for the owner. One
  exception: a feature PR may add **new** scenarios, fixtures and checks for its own feature. Mark each `written in this
  PR` in the evidence bundle; they judge nothing until merged into the champion's manifest. Changing an existing
  scenario, guard, band or fixture stays its own PR (docs/VERIFICATION.md §5, decision 1).
- **Never make the app aware of the bench**: no `PERFLOOP_` checks outside knobs, no fixture names, no "if measured"
  branches. A blank row that is fast is still a blank row; the guards exist because the search will find it.
- **Never pass `--guard-tolerance`, `--owner`, `--force` or `--allow-dirty`, never run `perfloop champion set` or
  `perfloop exp replay --go`, and never set `PERFLOOP_OWNER`.** They exist for the owner (the champion is what every
  verdict is judged against: the owner sets the first one, and it moves only when your experiment wins and is
  promoted): the CLI refuses them (exit 6) unless `PERFLOOP_OWNER=1` is set or someone types yes at a
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

`exp new` (it screens), `exp screen`, `exp full`, `run`, `baseline`, `guards`, `profile`, `sweep` and a bench's `run`/`ab` open a window
and take focus for seconds to minutes. Run them only when the owner says the Mac is free, or queue them: `perfloop queue
add <id>` and let `perfloop queue run --runner local --idle 120` (only while nobody touches the Mac) or
`--runner ssh://user@spare-mac` (a Mac nobody uses) take them. `--runner vm:tart/NAME` (a macOS VM on this Mac, screens
only) waits on the same idle gate, read on this Mac, with the same flags.

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

Every command refuses an argument it doesn't take (exit 1, naming it, with the command's usage) before it reads a store
or opens a window; `perfloop COMMAND --help` prints the usage. Pass a flag and its value as two arguments: a shell
variable holding `--store DIR` is one argument in zsh, and is refused.

Headless and always fine: `doctor`, `describe`, `store list`, `exp status`, `explain`, `ledger`, `champion`, `causes`.

Disk: every build in the store is a copy of the bench (`perfloop store gc` keeps the newest 20 and every champion);
traces are hundreds of MB. Delete what you made once its numbers are recorded.

Traces: `perfloop profile` deletes the `.trace` once exported and its `trace:` line says what is on disk: `deleted`, or
`KEPT at <path>` (`--keep-trace`, or a delete that failed: the notes say why). A kept trace holds the recorded process's
environment: perfloop starts the profile with a scrubbed one (README: Where things live), but delete it once read
anyway (`perfloop store gc --traces`). `perfloop doctor` fails while a stray
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
- A champion `champion merged` refuses for good: a PR that was squash-merged or rebased (its build commit is never on
  main), or a champion built with uncommitted changes (they can't be checked against main; only the owner may mark it
  merged). Either way the owner sets a clean build of main as the champion (`champion set BUILD --merged`); until then
  your experiments go on against the unmerged champion.

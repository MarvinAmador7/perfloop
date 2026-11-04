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
4. **Read the verdict, don't argue with it.** `rejected`: drop the change (reset your work branch) and go back to 1.
   `promising`: run the full. `won`: promote and open a PR. `lost`: drop it. `needsReview`: stop and ask the owner.
5. **Stop** when `exp status` prints `stop:` (the budget is met, no cost ≥ 5 % of the objective is left that you can
   attribute, 5 non-promising candidates in a row, or 2 h / 20 candidates spent), and report from the ledger: what you
   tried, what won, what's left.

## Never

- **Never edit what judges you**: the bench target (scenarios, fixtures, guards, checks), the manifest, PROGRAM.md, the
  store (`~/.perfloop`), the PerfLoop package itself. The runner reads the rules from the *champion's* manifest, so a candidate
  that changes them is judged by the old ones anyway; changes to the bench are their own PR for the owner.
- **Never make the app aware of the bench**: no `PERFLOOP_` checks outside knobs, no fixture names, no "if measured"
  branches. A blank row that is fast is still a blank row; the guards exist because the search will find it.
- **Never pass `--guard-tolerance`, `--owner`, `--force` or `--allow-dirty`** unless the owner told you to in this
  session. They exist for the owner.
- **Never commit or publish `.trace` files**, stores, results with paths from someone's home, or anything with
  secrets. xctrace traces embed the recorded process's environment (tokens included). `exp new` refuses a patch that
  touches a `.trace` or a path the manifest lists in `privatePaths`.
- **Never send synthetic input to the system** or click around the owner's Mac. Benches drive the app in-process.
- **Never leave processes behind**: no wait loops, watchers or benches running when you stop (`ps` to check; note that
  `pgrep -f` matches itself).

## The machine

`exp new` (it screens), `exp screen`, `exp full`, `guards` and a bench's `run` open a window and take focus for
seconds to minutes. Run them only when the owner says the Mac is free, with the window lock if other benches share it
(`--runner local --lock /tmp/window.lock`), or queue them: `perfloop queue add <id>` and let
`perfloop queue run --runner local --idle 120` (only while nobody touches the Mac) or
`--runner ssh://user@spare-mac` (a Mac nobody uses) take them. A run on a locked screen, in the background or under a
profiler is **untrusted** and never decides; rerun it, don't explain it away. `perfloop doctor` says what would make
this Mac's numbers untrustworthy.

Headless and always fine: `doctor`, `describe`, `store list`, `exp status`, `explain`, `ledger`, `champion`, `causes`.

Disk: every build in the store is a copy of the bench (`perfloop store gc` keeps the newest 20 and every champion);
traces are hundreds of MB. Delete what you made once its numbers are recorded.

## Ask the owner

- Any change in behaviour (what the user sees or can do): declare it with `--behaviour-change`; promotion then needs
  the owner.
- Feel and taste: animation curves, springs, gesture handling, spacing, what a placeholder shows. The bench measures
  smoothness, not feel.
- A `needsReview` verdict: a snapshot that doesn't look like the champion's (both pictures and a diff are in the
  experiment's folder), or no decision at 10+10 pairs.
- A guard, scenario or fixture you think is wrong or missing.
- Promoting a knob: the winning value becomes the default and the knob is deleted, in a follow-up change.

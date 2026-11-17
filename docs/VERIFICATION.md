# Agentic Verification

PerfLoop was built to make a native macOS app faster: a candidate either beats the champion or it doesn't. Most of
what a coding agent does to a Mac app is not that. It adds a sidebar, a palette, a split, and before it says "done" it
has to show that the change works, looks right, answers real input and costs nothing. This file defines that job,
**Agentic Verification**, as PerfLoop's second mode: what an agent must answer, the evidence for each answer, the
verdicts, what goes into a PR, and the order to build what is missing.

It is grounded in a friction study of four agents that built capcomd Desktop features (a sidebar, the Needs-you reel,
a ⌘K palette, pane splits) through capcomd's protocol-1 adapter on 13–14 November 2026. Its findings are cited as
**S1–S24** here (they are not [BEYOND.md](BEYOND.md)'s F-numbers). The headline: with no way to run or judge a
feature's own scenarios, the agents ran the bench directly about twice as often as through perfloop (57 Bash calls
against 28 windowed perfloop runs), outside the ledger, the gate and the lock (S5); every hand-written "is it drawn"
check caught a real bug, one of them in a build whose latency had *improved* (S14); and friction cost roughly 40–50 % of
each agent's active time. The trust fixes (S1–S4, S9–S11) are merged; this file is about the rest.

## 1. The question before "done"

| # | The agent claims | What would show it | What PerfLoop gives today | Missing (study) |
|---|---|---|---|---|
| 1 | **It works**: the feature does what it says | The scenario's checks pass in every trusted rep; existing scenarios' checks still pass against the champion's | `checks[]` per rep; a check the candidate fails while the champion passes vetoes (`guardFailures`), read from the champion's manifest | New scenarios can't run through perfloop at all (S5); checks race the first commit after a structural change (S17); a check that passes 2 of 3 reps reads as a pass |
| 2 | **It is drawn**: the views the user should see have content | The named regions have ink after settle, above a floor or near the champion's | `snapshot-diff` (whole window vs the champion); deskbench's `built-within` knows only the reel | No generic ink guard (S14); guard work counted inside a step (S18) |
| 3 | **It answers real input**: the key, shortcut or click reaches the intended target and focus lands where it should | The event goes through the app's own queue; the step records which menu item fired, which view took the click, and the first responder before and after | Gesture replay for scrolls only (`run.swipe`) | No key, type or click helpers; `sendEvent` vs `postEvent` cost palette ~20 min, a misrouted ⇧⌘D cost splits ~30 min (S12); no focus or hit record (S13) |
| 4 | **It looks right**: what changed is what was meant to, and it is readable | Snapshots differ from the champion only inside declared regions; child windows and materials captured; text contrast ≥ 4.5:1 | `snapshot-diff` pixel-to-pixel, global 0.5 % tolerance, `REVIEW` sends it to the owner | No regions, no alignment, no way to declare an intended change (S16); child panels, vibrancy and title bar missing from `cacheDisplay` snapshots, no contrast or accessibility guard (S15) |
| 5 | **It costs nothing** (a feature) or **it is faster** (an optimisation) | Existing scenarios: no change worth calling, in interleaved trusted pairs. New scenarios: first numbers, with a same-minute yardstick | The optimise loop: `promising`/`rejected`, `won`/`lost` | A feature gets `REJECTED`, "drop it" and a stop streak (S6); a wide 3-pair screen closes the experiment (S7); no numbers for a scenario the champion lacks (S5) |

Every answer comes under the loop's trust rules, unchanged:

| Rule | What it means for verification |
|---|---|
| **Interleaved, counterbalanced pairs** | "Costs nothing" and "looks the same" are always claims against the champion, measured in the same minutes. A one-build `run` gives numbers and check results, never a comparison verdict |
| **Idle and quiet gated, screen unlocked** | A window check needs a real window: a locked screen draws nothing and is never key. The same gate runs before every rep of every mode |
| **One window lock** | `run`, `baseline` and every guard rep take it, so a feature's scenarios never need a direct bench run (S5's 57 ran outside the gate and the ledger, most under hand-made locks) |
| **Untrusted never decides** | A check or guard result from an untrusted rep is reported and never counts, pass or fail: a focus check fails on a locked screen, an ink check passes on a stale frame. A stage short of trusted reps says `UNTRUSTED` with the count and why |
| **The agent can't edit the judge** | The champion's manifest names the scenarios, fixtures, checks and guards that judge existing behaviour. A feature PR's *new* scenarios and checks are the agent's own claims, not a judge: the bundle marks them `written in this PR` for the reviewer (§3, decision 1). Built-in guards (ink, focus, input, looks, contrast) are PerfLoop's code, so they judge new scenarios too: that is why they belong here and not in each adapter |

## 2. Verdicts, by mode

| Mode | Verb | Question | Verdicts | Decides | Ledger | Status |
|---|---|---|---|---|---|---|
| Optimise | `exp new` (screen), `exp full`, `exp promote` | Is the candidate faster, with every guard holding? | screen `promising` · `rejected` · `needsReview`; full `won` · `lost` · `unknown` → `noDecision` · `needsReview`; both `untrusted` · `error` | Promotion of a new champion | a line per state | built |
| Screen too wide to call | `exp screen ID --more N` | Do more pairs settle a borderline screen? | `inconclusive` (the band is over the gain threshold, or the signs are mixed); `rejected` kept for "slower in every pair" or a failed guard | Lets `exp full` run with no owner flag | `inconclusive` | **in progress** (b3) |
| No regression | `exp new --expect same` (then `exp screen --more`, `exp full`) | Does a feature branch leave existing scenarios where they were? | `noRegression` (the cost's one-sided 95 % high bound under its margin, on the objective and each frame guard) · `regressed` (a guard failed, or the low bound is over the margin) · `inconclusive` (the interval straddles it); and `untrusted`. The margin is the metric's floor (`Acceptance.floors`: 5 % CPU, 15 % latency, …), not the run's band. A snapshot unlike the champion's is listed as a look for the PR, not a verdict, until v5 | Nothing is promoted: the evidence for a PR. No "drop it", outside the stopping rules | `noRegression` · `regressed` · `inconclusive` | **in progress** (b2) |
| Measure | `perfloop run champion\|exp/ID\|BUILD\|BENCH --scenario S [--fixture F] [--reps N] [--reference S2]` | What does this build do on S, with what checks? The scenario may be one only this build has | none: numbers, checks and guards as facts, the trust summary, the champion's S2 beside each rep as a yardstick; exit 3 when a check failed, 5 when no rep could be trusted | Nothing | `measure` (stored under `runs/`, `explain run/ID`) | built (#9, b1) |
| Baseline | `perfloop baseline S --bench PATH\|--build HASH [--fixture F] [--reps N] [--reference S2]` | First numbers and a reference snapshot for a scenario the champion lacks | none; once a champion has S, `run champion --scenario S` is compared with it. Trusted reps only: nothing is recorded when none could be trusted | Becomes the yardstick for S | `baseline` | built (#9, b1) |
| Drawn | guard `ink` (regions by rect or accessibility identifier) | Do the regions have content after settle? | per region `pass` / `fail` with the ink share against a floor, or against the champion's share where it has the region | Vetoes like any guard | in the stage | planned (v3) |
| Focus | step record `focus {before, after}` + check | Is the first responder (or field editor) where it should be? | `pass` / `fail`, naming the responder's class and identifier | Vetoes as a check | in the stage | planned (v4) |
| Input fired | `run.press` / `run.type` / `run.click` | Did the event reach its target? | `fired <menu item>` · `fired <other item>` (fails) · `not fired`; a click reports the hit view and what took the mouse-down, or `nobody` | Vetoes as a check | in the stage | planned (v4) |
| Looks | `snapshot-diff` with regions and `--expect-look R` | Did the picture change only where the change was declared? | per region `same` · `moved N pt` · `differs`; outside declared regions over tolerance: `REVIEW` (the owner); inside them: listed, not a review | `REVIEW` waits for the owner, never a win | in the stage | planned (v5) |
| Readable | guard `contrast` over named text regions; optional AX audit | Text ≥ 4.5:1 against its local background; controls labelled | `pass` / `fail` with the ratio; audit findings as a list | Decision 4 | in the stage | planned (v8) |

`untrusted` is a verdict in every mode, and `FORCED (owner flag)` is printed on any stage an owner flag changed.
The `run` and `baseline` rows are as merged in #9; the in-progress rows follow PR #8 (`--expect same`, `--more`) as this
is written, and #8 is the reference where they differ.

## 3. The evidence bundle

One block of text an agent pastes into its PR, and the files behind it in the store. Written by `perfloop verify`
(§4, v6) as `verification.txt` and `verification.json` (`perfloop.verification/1`) under the store's
`verify/<id>/`; until then, the agent assembles the same sections from `explain` and `ledger`.

| Section | Lines | A reviewer reads it for |
|---|---|---|
| Header | champion build and commit (and whether merged), candidate build and commit, runner and machine, one trust line (`18/18 reps trusted` or `UNTRUSTED 4/18: not quiet ×4 (swift-build)`), owner flags used | Were these the right builds, on a machine that could tell? |
| Costs nothing | one line per existing scenario: `switch: noRegression · 5+5 pairs · +1.2 % (90 % interval −0.8 … +3.4 %, margin 15 %)`; `regressed` with the worst stretch's top frame; `inconclusive` with what would settle it | Did anything get slower, by how much, and how sure? |
| New scenarios | per scenario: the measured objective and checks over N trusted reps, the `--reference` scenario's numbers from the same minutes, and `written in this PR` on every check and guard the champion's manifest doesn't have | What does the new thing cost, and which claims did the agent write itself? |
| Works and drawn | each check and built-in guard, `✓ N/N trusted reps`; `flaky 2/3` is a failure, not a pass | Does it work every time, not once? |
| Input and focus | per step: the key or click, what fired or was hit, the first responder after | Did real input do what the scenario says? |
| Looks | per scenario and region: `same` / `moved` / `differs`, the declared regions, and the picture paths relative to the store (`diff.png`, both sides) | Look at the two pictures where it says `differs` |
| Not verified | scenarios skipped (and why), untrusted stages, guards the adapter can't run (`ink: not available in this adapter`), and always: feel, motion and taste | What is still the owner's call? |

The ledger keeps the verification's own line (`verified` / `regressed` / `inconclusive` / `untrusted`, with the bundle's
id in `note`) after the lines of the experiments and runs it made, so `perfloop ledger` shows what a PR's claims came
from. Pictures stay in the store; the bundle names them and never embeds a path from someone's home, and nothing in it
comes from a `.trace`. The bundle goes in the PR body, not in a committed file.

## 4. Roadmap

Re-ordered for verification from the study's (b) and (c) rows. Sizes: S ≈ a day, M ≈ a few days, L ≈ a week or more.

| # | Item | Study | Size | Status | Why here |
|---|---|---|---|---|---|
| v1 | `perfloop run` (one build, gated, locked, stored, no verdict), `perfloop baseline`, `--reference` yardstick; per-scenario `fixture` in the manifest, `--fixture` validated, fixture-ran in results (b1, b4) | S5, S8 | M + S | built (#9) | Ends the bypasses: nothing else can be judged until a new scenario can be run inside the gate |
| v2 | `exp new --expect same` with `noRegression` / `regressed` / `inconclusive`; `inconclusive` screens and `exp screen --more N` (b2, b3) | S6, S7 | M + S | **in progress** (`expect-same`) | The "costs nothing" answer, without the optimiser's words |
| v3 | `ink` guard over named regions, run in its own run-loop turn after the step; `explain` warns when a step's worst stretch is bench code (c3, c6) | S14, S18 | M | planned | Caught a real bug in all four features; generic, so it judges new scenarios the agent can't have tuned |
| v4 | `run.press` / `type` / `key` through `NSApp.postEvent` with layout-correct characters, reporting the menu item fired; `run.click` with hit and consumer; focus before and after each step (c1, c2) | S12, S13 | M + M | planned | The ~65 min the study lost to input; "it answers real input" has no evidence without it |
| v5 | Region-scoped `snapshot-diff`, an alignment search (`moved` vs `differs`), regions declared by the agent with `--expect-look` (b5) | S16 | M | planned | Every feature changes the picture somewhere; today that is a global `REVIEW` the owner has to open |
| v6 | **`perfloop verify`** and the bundle (§3); an MCP `verify` tool that returns a job | new | S, then grows | planned, after v1–v2 | See below |
| v7 | Visible child windows drawn into the default snapshots (c4, first part) | S15 | S | planned | A palette or popover is invisible to every looks check without it |
| v8 | Opt-in ScreenCaptureKit `looks` capture (materials, title bar), the `contrast` guard, an optional AX audit (c4, rest) | S15 | L | planned | Needs the screen-recording permission (decision 3) |
| v9 | Checks counted per trusted rep: `flaky N/M` instead of a pass; `until:`/`wait`/`settle` documented, and doctor names a protocol-1 adapter without PerfLoopHost's helpers (c5 docs) | S17 | S | planned | A check that races the first commit passes one rep and fails the next |
| v10 | Busy % and load per rep in the pair lines, a body-count delta per step (load-independent) (b6) | S23 | S | planned | On a busy Mac, structure is the only evidence left; it turns some `inconclusive` into readable |
| v11 | Appearances: `--set appearance=dark` and the larger text sizes as a scenario parameter the bench applies, so looks, ink and contrast run in each | new | S | planned | The study never checked dark mode; every looks claim is for one appearance |
| v12 | `exp new --base BUILD` (b7) | S24 | M | later | Convenience: knob A/B on a branch build without a second store |
| – | capcomd: move DeskBench onto PerfLoopHost (c5) | S17, S20 | M (capcomd) | capcomd's | Until then v3–v5 reach capcomd only if its adapter rebuilds them |

**`perfloop verify`: worth it, kept thin.** It judges nothing itself. Given the bench and the PR's new scenarios, it
runs `exp new --expect same` on the champion's scenarios and `run` (and `baseline` when asked) on the new ones, as one
gated, locked job (one MCP job, one `^C`), then writes the bundle and exits 0 verified, 3 regressed or a check failed,
5 untrusted or inconclusive, 6 refused (the codes `run` uses), so capcomd's verify gate or CI can call it. It earns a
verb because the study's agents bypassed perfloop when the one-shot path was missing, and because a bundle needs one
place that knows which pieces belong to one claim. The risk is choice: the agent must not pick which existing
scenarios get checked. The default is the manifest's `verify` list (the owner's), else every champion scenario; the
agent can add scenarios, never drop one, and anything skipped is printed under "Not verified" (decision 2).

## 5. Owner decisions

| # | Decision | Recommendation |
|---|---|---|
| 1 | May a feature PR add scenarios, fixtures and checks to the bench, when AGENTS.md says "never edit what judges you"? | Yes for **new** scenarios only, each marked `written in this PR` in the bundle; they judge nothing until the PR is merged and they are in the champion's manifest. Changes to existing scenarios, guards, bands or fixtures stay their own PR. Update AGENTS.md "Never" with that line |
| 2 | Which existing scenarios must `perfloop verify` check by default? | A `verify` list in the manifest, set by the owner (a fast subset, ~5 min of windows); every scenario when absent. The agent adds, never removes |
| 3 | ScreenCaptureKit looks capture needs the screen-recording permission, and the README promises none | Opt-in only (`--looks`), never a default, with a doctor check; keep `cacheDisplay` plus child windows (v7) as the default |
| 4 | Do `contrast` and the AX audit veto, or report? | Contrast vetoes only a regression against the champion's region; a new region under 4.5:1 is `REVIEW`. The AX audit reports and never vetoes until it has run on two apps |
| 5 | Who accepts a declared look change (`--expect-look`)? | The agent declares it; the PR's reviewer accepts it by reading the region's pictures. A difference outside the declared regions stays `REVIEW` for the owner |
| 6 | Is `noRegression` an agent's verdict, and is its margin right? | Yes: nothing is promoted, so no owner step. The in-progress margin is each metric's floor (5 % for CPU, 15 % for latency, with absolute floors), held by a one-sided 95 % bound: keep it, and let a scenario's manifest entry tighten it. `inconclusive` is reported as such in the PR, never rounded to "no regression" |
| 7 | Where does the bundle live? | In the PR body; the files stay in the store and are never committed (paths, pictures, possibly fixture data) |

## 6. What not to claim

None of v3–v12 is built, and no agent has verified a feature through `perfloop verify` yet; v1 is merged (#9) and
v2 is in review (#8) as this is written. `noRegression` means no change beyond the metric's margin on these scenarios,
fixtures, appearance and machine, not no change. Checks the agent wrote in the same PR show what the agent believes the
feature does, not that it is what the owner asked for. In-process input goes through the app's event queue, not the
HID path, input methods or accessibility clients: it proves routing, not that a hand on a keyboard gets the same
result. An ink guard proves something was drawn, not that it is the right thing; a snapshot proves a picture on this
display's scale and colour space. Feel, motion and taste stay the owner's call. The study's own numbers were untrusted
(a shared, busy and partly locked Mac); what it shows is how agents used the tool, not what the app costs.

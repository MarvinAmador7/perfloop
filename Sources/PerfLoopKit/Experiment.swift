import Foundation

/// An experiment's life (SCHEMAS.md §6). `new` → `built` → screened: `promising` | `inconclusive` (more pairs, or the
/// full) | `rejected` → full: `won` | `lost` | `needsReview` (no decision at 10 + 10, or a guard asks the owner) →
/// `promoted` | `abandoned`. An expect-same experiment (a feature or guard check, `exp new --expect same`) ends
/// `noRegression` | `regressed`, or stays `inconclusive`; it never moves the champion.
public enum ExpState: String, Codable, Sendable, CaseIterable {
  case new, built, screened, promising, rejected, full, won, lost, needsReview, promoted, abandoned
  case inconclusive, noRegression, regressed
  /// Nothing more will happen to it.
  public var terminal: Bool { [.rejected, .lost, .promoted, .abandoned, .noRegression, .regressed].contains(self) }
}

/// `perfloop.experiment/1`: one hypothesis, one build or knob vector, its screen and full against the champion it
/// was created on. Paths are relative to the store root.
public struct Experiment: Codable, Sendable, Equatable {
  public var schema = "perfloop.experiment/1"
  public var id: String
  public var createdAt: String
  public var state: ExpState
  public var hypothesis: String
  /// code | knob | baseline (the first champion, set by hand).
  public var kind: String
  /// What the experiment expects of the candidate: nil, faster (the optimisation loop: promising, won, promoted); or
  /// "same": a feature or guard check that it costs nothing (`noRegression` | `regressed` | `inconclusive`), which
  /// gets no "drop it", stays out of the stopping rules, and is never promoted.
  public var expect: String?
  public var behaviourChange: Bool
  /// The champion at creation.
  public var parent: ParentRef?
  public var patch: String?
  public var knobs: [String: String]?
  public var build: Build?
  public var scenario: String
  public var fixture: String
  public var secondFixture: String?
  public var params: [String: String]?
  /// How a pair is measured: `ab` (the adapter alternates two binaries; the default) or `run` (one child per side;
  /// knob experiments, and adapters whose `ab` predates the objective).
  public var via: String?
  public var screen: Stage?
  public var full: Stage?
  /// The screen on the second fixture after a win: promotion needs it not worse (SPEC §5.5).
  public var secondScreen: SecondFixture?
  public var confirmation: JSONValue?
  /// The isolation scenarios' checks (C6), run once the full has won: a promotion needs every one to hold.
  public var isolation: [IsolationGuard]?
  /// `perfloop guards --exp ID` runs, oldest first.
  public var guardRuns: [GuardRun]?
  /// Guard parameters the owner set for this experiment (`perfloop guards --guard-tolerance X --owner`), on top of the
  /// champion manifest's for every later pair.
  public var guardParams: [String: JSONValue]?
  public var diff: String?
  public var explain: String?
  public var promotedAt: String?
  public var pr: String?
  /// An owner flag changed what happened to it (`ownerFlags` says which, how it was authorised, and what it did).
  /// Printed in the verdict, `explain`, `exp status` and the ledger, so a PR can't leave it out unnoticed.
  public var forced: Bool?
  public var ownerFlags: [OwnerFlagUse]?
  public var notes: [String]

  public init(id: String, hypothesis: String, kind: String = "code", scenario: String, fixture: String, parent: ParentRef?, build: Build?) {
    self.id = id; createdAt = Clock.now(); state = build == nil ? .new : .built; self.hypothesis = hypothesis; self.kind = kind
    behaviourChange = false; self.parent = parent; self.build = build; self.scenario = scenario; self.fixture = fixture; notes = []
  }

  /// Records an owner flag's use (once per flag and command run).
  public mutating func used(_ u: OwnerFlagUse) {
    if ownerFlags?.contains(where: { $0.flag == u.flag && $0.command == u.command && $0.at == u.at }) == true { return }
    ownerFlags = (ownerFlags ?? []) + [u]; forced = true
  }
}

public struct ParentRef: Codable, Sendable, Equatable {
  public var experiment: String
  public var build: Build
  public init(experiment: String, build: Build) { self.experiment = experiment; self.build = build }
}

/// One interleaved pair: champion and candidate, one rep each, in the order run.
public struct Pair: Codable, Sendable, Equatable {
  public var index: Int
  /// "AB": the champion ran first. Randomised per pair (SPEC §5.1, FEASIBILITY.md ref 13).
  public var order: String
  /// The adapter's output for the pair, relative to the store root.
  public var result: String?
  public var a: Side
  public var b: Side
  /// Why the pair has no numbers (the child failed); a failed pair is re-run on resume.
  public var failure: String?
  /// Where it ran (C10): a stage's pairs all come from one runner.
  public var runner: RunnerIdentity?
  /// The runner aborted a rep of this pair on input (the local runner's idle gate) and the pair was redone this many times.
  public var interruptions: Int?
  /// This record is an aborted rep (input arrived): never judged, always redone.
  public var interrupted: Bool?
  /// Why the pair's first attempt couldn't decide (it failed or was untrusted), when this record is its one redo.
  public var redone: String?
  public init(index: Int, order: String, result: String?, a: Side, b: Side, failure: String? = nil) {
    self.index = index; self.order = order; self.result = result; self.a = a; self.b = b; self.failure = failure
  }
}

/// One side of a pair: the objective and the guard inputs.
public struct Side: Codable, Sendable, Equatable {
  public var objective: Double?
  public var hitchTimeRatioMsPerS: Double?
  public var longestStretchMs: Double?
  public var checksFailed: [String]
  /// The checks the rep passed, when it lists them (`checks[]` of a result); nil for an `ab` summary, which lists only
  /// the failed ones. With it, a check another rep reported and this one didn't counts as not passed (Checks.swift).
  public var checksPassed: [String]?
  /// Present only when the run says so; a profiled or untrusted rep never decides.
  public var profiled: Bool?
  public var trustworthy: Bool?
  /// The `window` fields that were wrong (`keyWindow`, `appActive`, `visible`, `occluded`), when `trustworthy` is false.
  public var windowFailed: [String]?
  /// The rep's exit code, when the runner or the adapter's `ab` reports it: 5 is the bench's own "untrusted".
  public var exit: Int?
  /// Whether the machine was quiet when the rep started, the share of the cores busy then, and what kept them busy
  /// (`ab`'s `runs[]`, or the result's `quiet` / `noise.quiet`, or the local runner's quiet gate: false when either saw
  /// a busy machine). nil when nobody checked.
  public var quiet: Bool?
  public var busyPct: Double?
  public var busy: [String]?
  public var steadyHz: Double?
  public var lateFrames: Double?
  public var worstStretch: StretchNote?
  /// Correctness guards the side's run reported (C6), plus, on the candidate, the runner's pairwise `snapshot-diff`.
  public var guards: [GuardResult]?
  /// A replayed gesture's smoothness (C9, `reps[].smoothness`): content-to-finger error p95 in pt, stalls, jerk p95.
  /// nil when the scenario replays none.
  public var positionErrorP95Pt: Double?
  public var stalls: Double?
  public var jerkP95: Double?
  /// The local runner's quiet gate when the rep started (it also sets `quiet`, `busyPct` and `busy` above): how long
  /// it waited and why the machine wasn't quiet. nil when the runner didn't check (ssh, VM, a library caller).
  public var machine: MachineState?
  /// The rep presented no frames (the screen was locked, or the window was off-screen): its frame metrics are
  /// missing, not 0, and the rep is untrusted (it never decides).
  public var noFrames: Bool?
  /// The fixture the rep says it ran on (the result's `fixture`), when it says; the runner checks it against the one
  /// it asked for.
  public var fixture: String?
  public init(objective: Double?, hitch: Double? = nil, longest: Double? = nil, checksFailed: [String] = []) {
    self.objective = objective; hitchTimeRatioMsPerS = hitch; longestStretchMs = longest; self.checksFailed = checksFailed
  }
}

/// The worst stretch of a rep, as much as `explain` needs: where the main thread's time went.
public struct StretchNote: Codable, Sendable, Equatable {
  public var durationMs: Double
  public var step: String?
  public var topOurs: [String]
  public var topFramework: [String]
  /// What the stretch's bodies followed (`causes[]`, C7), as `CauseTable.line` writes it; nil when the adapter records none.
  public var causes: String? = nil
  /// The share of the stretch's samples that were the bench's own code, not the app's (`worstStretches[].benchSamples`
  /// / `samples`), and those frames (`topBench`); nil when the adapter doesn't say.
  public var benchPct: Double? = nil
  public var topBench: [String]? = nil
  public init(durationMs: Double, step: String?, topOurs: [String], topFramework: [String], causes: String? = nil) {
    self.durationMs = durationMs; self.step = step; self.topOurs = topOurs; self.topFramework = topFramework; self.causes = causes
  }

  /// The bench measured itself: `Explain.benchWarnPct` or more of the stretch was its own code.
  public var benchWarning: String? {
    guard let p = benchPct, p >= Explain.benchWarnPct else { return nil }
    return "\(Explain.fmt(p)) % of the worst stretch\(step.map { " (\($0))" } ?? "") is the bench's own code, not the app's"
      + (topBench.flatMap { $0.isEmpty ? nil : " (\($0.prefix(3).joined(separator: "; ")))" } ?? "")
      + ": the bench measured itself. Run checks and captures after the step, in their own run-loop turn (PerfLoopHost: run.step(…, ink:), "
      + "`await run.check(name) { … }`), never in the step's action or its until: (ADAPTER.md §3b)"
  }
}

/// A screen or full stage's record (SCHEMAS.md §6 `screen` / `full`, both kept in one shape).
public struct Stage: Codable, Sendable, Equatable {
  public var metric: String
  public var pairs: [Pair]
  /// The champion's (a) and candidate's (b) objective values, from the pairs that ran.
  public var objective: [String: [Double]]
  public var wins: Int
  public var medianGainPct: Double?
  /// The noise band, % of the champion's median.
  public var band: Double?
  public var guardsPassed: Bool
  public var guardFailures: [String]
  /// Guards over tolerance that ask the owner (a snapshot unlike the champion's): the stage can't be won, it is
  /// `needsReview`.
  public var guardReviews: [String]?
  /// promising | rejected (screen); won | lost | unknown | noDecision (full); needsReview (either: the objective
  /// would pass but a guard asks the owner); untrusted (either: pairs it needs had untrusted reps, so it decided
  /// nothing); error when no pair produced numbers.
  public var verdict: String
  /// How many reps couldn't be trusted and why ("6/6 reps untrusted: not quiet ×6 (busy up to 99.8 %: swift-build)"),
  /// whatever the verdict; nil when every rep could.
  public var untrusted: String?
  public var reasons: [String]
  /// The candidate is worse than the champion beyond the band (full: and significantly; expect same: a cost's low
  /// bound over its margin). Never set by noise alone.
  public var regression: Bool?
  /// Expect same: what the candidate costs on the objective, then on each frame guard both sides report.
  public var costs: [CostBound]?
  public var repsPerSide: Int?
  /// The pairs the stage was asked for, when more than its first look's: the full's extension, a screen's `--more`.
  public var extendedTo: Int?
  // Full only.
  public var mwuP: Double?
  public var signP: Double?
  public var effectPct: Double?
  public var frameGuards: [String: FrameGuard]?
  /// The runner every pair ran on (C10).
  public var runner: RunnerIdentity?
  public init(metric: String, pairs: [Pair], verdict: String) {
    self.metric = metric; self.pairs = pairs; objective = ["a": [], "b": []]; wins = 0; guardsPassed = true; guardFailures = []
    self.verdict = verdict; reasons = []
  }
}

/// What a candidate costs on one metric (expect same): the mean per-pair difference, candidate − champion, in the
/// metric's units (positive: slower, or worse), its 90 % interval (`PairedT`), and the margin it is held to.
public struct CostBound: Codable, Sendable, Equatable {
  public var metric: String
  /// The champion's median over the pairs: what the percentages are of.
  public var champion: Double
  public var change: Double
  /// One-sided 95 % bounds on `change`; nil with one pair.
  public var low: Double?
  public var high: Double?
  /// The smallest change worth calling (`Acceptance.floors`: a share of the champion's median, or the metric's
  /// absolute floor), never the run's noise band.
  public var margin: Double
  /// same: `high` < `margin` · worse: `low` > `margin` · unsure: neither (the interval straddles the margin).
  public var call: String
  public init(metric: String, champion: Double, change: Double, low: Double?, high: Double?, margin: Double, call: String) {
    self.metric = metric; self.champion = champion; self.change = change; self.low = low; self.high = high; self.margin = margin; self.call = call
  }

  /// `x` as a signed % of the champion's median, or in the metric's units (`units`, or when the median is 0).
  public func show(_ x: Double, units: Bool = false) -> String {
    let u = units || champion == 0
    let v = u ? Stats.round(x, 2) : Stats.round(x / abs(champion) * 100, 1)
    return (v > 0 ? "+" : "") + Explain.fmt(v) + (u ? "" : " %")
  }
  /// "+1.2 % (90 % interval -0.8 % … +3.4 %, margin 5 %)"; `units`: in the metric's units ("+0.4 (… margin 2)").
  public func text(units: Bool = false) -> String {
    let m = show(margin, units: units).replacingOccurrences(of: "+", with: "")
    let ci = low.flatMap { l in high.map { "90 % interval \(show(l, units: units)) … \(show($0, units: units)), " } } ?? "one pair: no interval, "
    return "\(show(change, units: units)) (\(ci)margin \(m))"
  }
  public var text: String { text() }
}

public struct FrameGuard: Codable, Sendable, Equatable {
  public var a: Double
  public var b: Double
  public var bandPct: Double
  public var pass: Bool
}

public struct SecondFixture: Codable, Sendable, Equatable {
  public var fixture: String
  public var stage: Stage
  public var notWorse: Bool
  public init(fixture: String, stage: Stage, notWorse: Bool) { self.fixture = fixture; self.stage = stage; self.notWorse = notWorse }
}

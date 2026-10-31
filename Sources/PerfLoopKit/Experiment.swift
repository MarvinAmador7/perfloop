import Foundation

/// An experiment's life (SCHEMAS.md §6). `new` → `built` → screened: `promising` | `rejected` → full: `won` | `lost` |
/// `needsReview` (no decision at 10 + 10, or a guard asks the owner) → `promoted` | `abandoned`.
public enum ExpState: String, Codable, Sendable, CaseIterable {
  case new, built, screened, promising, rejected, full, won, lost, needsReview, promoted, abandoned
  /// Nothing more will happen to it.
  public var terminal: Bool { [.rejected, .lost, .promoted, .abandoned].contains(self) }
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
  public var notes: [String]

  public init(id: String, hypothesis: String, kind: String = "code", scenario: String, fixture: String, parent: ParentRef?, build: Build?) {
    self.id = id; createdAt = Clock.now(); state = build == nil ? .new : .built; self.hypothesis = hypothesis; self.kind = kind
    behaviourChange = false; self.parent = parent; self.build = build; self.scenario = scenario; self.fixture = fixture; notes = []
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
  /// Present only when the run says so; a profiled or untrusted rep never decides.
  public var profiled: Bool?
  public var trustworthy: Bool?
  public var steadyHz: Double?
  public var lateFrames: Double?
  public var worstStretch: StretchNote?
  /// Correctness guards the side's run reported (C6), plus, on the candidate, the runner's pairwise `snapshot-diff`.
  public var guards: [GuardResult]?
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
  /// would pass but a guard asks the owner); error when no pair produced numbers.
  public var verdict: String
  public var reasons: [String]
  /// The candidate is worse than the champion beyond the band (full: and significantly). Never set by noise alone.
  public var regression: Bool?
  // Full only.
  public var repsPerSide: Int?
  public var extendedTo: Int?
  public var mwuP: Double?
  public var signP: Double?
  public var effectPct: Double?
  public var frameGuards: [String: FrameGuard]?
  public init(metric: String, pairs: [Pair], verdict: String) {
    self.metric = metric; self.pairs = pairs; objective = ["a": [], "b": []]; wins = 0; guardsPassed = true; guardFailures = []
    self.verdict = verdict; reasons = []
  }
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

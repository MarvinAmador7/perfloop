import Foundation

/// `perfloop.measure/1`: one build's scenario measured on its own (`perfloop run`, `perfloop baseline`). The reps go
/// through the runner's gates like a pair's sides and are judged for trust the same way (Acceptance.distrust), but
/// there is no champion on the other side and so no verdict: numbers, where the time went, the checks, and what the
/// untrusted reps were. A feature's own scenario, one the champion doesn't have yet, is measured this way.
public struct ScenarioRun: Codable, Sendable, Equatable {
  public var schema = "perfloop.measure/1"
  /// `m0001`, …: the folder under the store's `runs/`.
  public var id: String
  public var createdAt: String
  /// run | baseline.
  public var kind: String
  /// What was asked for: champion, exp/0007, a build hash or a bench path.
  public var target: String
  public var build: Build
  public var scenario: String
  /// The fixture asked for. Each rep's `side.fixture` is the one the adapter says it ran on.
  public var fixture: String
  /// The scenario's own fixture in the build's manifest (`scenarios[].fixture`), when it names one.
  public var expectedFixture: String?
  public var metric: String
  public var knobs: [String: String]?
  public var params: [String: String]?
  public var reps: [MeasureRep]
  public var summary: MeasureSummary
  /// The champion's scenario interleaved with these reps (`--reference S`): the same minutes, a known yardstick.
  public var reference: MeasureReference?
  /// The scenario's stored baseline (`perfloop baseline`) and how this run sits against it; never a verdict.
  public var againstBaseline: BaselineComparison?
  /// A rep's snapshot against the baseline's reference picture (the champion's adapter's `snapdiff`, else this build's).
  public var snapshot: GuardResult?
  public var runner: RunnerIdentity?
  public var by: String
  public var notes: [String]
  /// The step to take next, for the agent reading it (the text's last line).
  public var next: String?

  public init(id: String, kind: String, target: String, build: Build, scenario: String, fixture: String, metric: String, by: String = "agent") {
    self.id = id; createdAt = Clock.now(); self.kind = kind; self.target = target; self.build = build; self.scenario = scenario; self.fixture = fixture
    self.metric = metric; reps = []; summary = MeasureSummary(); self.by = by; notes = []
  }
}

/// One rep of a measurement: the result as the runner read it, and whether it can be trusted.
public struct MeasureRep: Codable, Sendable, Equatable {
  public var index: Int
  /// The adapter's result for the rep, relative to the store root.
  public var result: String?
  public var side: Side
  /// Why the rep has no numbers (the child failed, or it ran another fixture than asked).
  public var failure: String?
  /// Why its numbers can't be trusted (Acceptance.distrust); nil when they can.
  public var untrusted: String?
  /// Why its first attempt couldn't be used, when this record is its one redo.
  public var redone: String?
  /// The runner aborted it on input this many times and redid it.
  public var interruptions: Int?
  /// "before" or "after" the reference's rep in the same minute, when there is a reference.
  public var order: String?

  public init(index: Int, result: String?, side: Side, failure: String? = nil) {
    self.index = index; self.result = result; self.side = side; self.failure = failure
    let d = Acceptance.distrust(side) + (side.profiled == true ? ["a profiler was attached"] : [])
    untrusted = failure == nil && !d.isEmpty ? d.joined(separator: "; ") : nil
  }

  /// Numbers that may be quoted: it ran, on the fixture asked for, and nothing makes it untrusted.
  public var trusted: Bool { failure == nil && untrusted == nil && side.objective != nil }
}

public struct MeasureSummary: Codable, Sendable, Equatable {
  /// Reps that ran (with numbers, trusted or not) and reps that failed.
  public var ran = 0
  public var failed = 0
  /// Reps whose numbers can be quoted; every number below comes from them only.
  public var trusted = 0
  public var values: [Double] = []
  public var median: Double?
  public var min: Double?
  public var max: Double?
  public var hitchTimeRatioMsPerS: Double?
  public var longestStretchMs: Double?
  /// "3/5 reps untrusted: not quiet ×3 (busy up to 99.8 %: swift-build)"; nil when every rep that ran could be trusted.
  public var untrusted: String?
  /// Every untrusted rep had its window wrong the same way: the build does that, a rerun can't help.
  public var deterministic: String?
  /// Checks and guards that failed in a trusted rep (the feature's own checks).
  public var checksFailed: [String] = []
  public var guardsFailed: [String] = []
  public init() {}
}

public struct MeasureReference: Codable, Sendable, Equatable {
  public var scenario: String
  public var fixture: String
  /// The champion it ran on.
  public var experiment: String
  public var build: Build
  public var metric: String
  public var reps: [MeasureRep]
  public var summary: MeasureSummary
  /// The champion's objective on that scenario from its own full stage, when it has one: how this Mac runs today
  /// against then.
  public var championObjective: Double?
  public init(scenario: String, fixture: String, experiment: String, build: Build, metric: String) {
    self.scenario = scenario; self.fixture = fixture; self.experiment = experiment; self.build = build; self.metric = metric; reps = []; summary = MeasureSummary()
  }
}

/// `perfloop.baseline/1` (`baselines/<scenario>/baseline.json`): the first numbers of a scenario the champion doesn't
/// have yet, from trusted reps only, and a reference snapshot. A later run of the scenario (on a champion that has it,
/// once the feature is merged) is compared with it.
public struct BaselineRecord: Codable, Sendable, Equatable {
  public var schema = "perfloop.baseline/1"
  public var scenario: String
  public var fixture: String
  public var metric: String
  /// The measurement it came from (`runs/<id>/run.json`).
  public var measurement: String
  public var build: Build
  public var createdAt: String
  public var trusted: Int
  public var reps: Int
  public var median: Double
  public var min: Double
  public var max: Double
  public var referenceScenario: String?
  public var referenceMedian: Double?
  /// The reference picture, relative to the store root (and its `.later.png` and `.layout.json` beside it).
  public var snapshot: String?
  public var replaces: String?
  /// The look it was measured in (`Looks.key`: `dark`, `light-text-xLarge`; nil for light at the default text size):
  /// each look has its own baseline, under `baselines/<scenario>~<key>/`.
  public var look: String?
  public init(scenario: String, fixture: String, metric: String, measurement: String, build: Build, trusted: Int, reps: Int, median: Double, min: Double, max: Double) {
    self.scenario = scenario; self.fixture = fixture; self.metric = metric; self.measurement = measurement; self.build = build; createdAt = Clock.now()
    self.trusted = trusted; self.reps = reps; self.median = median; self.min = min; self.max = max
  }
}

/// A run against its scenario's baseline: information about drift, never a verdict (other minutes, maybe another
/// fixture or machine state; only `exp` pairs decide).
public struct BaselineComparison: Codable, Sendable, Equatable {
  public var measurement: String
  public var build: Build
  public var median: Double
  public var min: Double
  public var max: Double
  /// This run's median against the baseline's, % (positive: higher, i.e. slower for every objective).
  public var deltaPct: Double
  /// The median falls inside the baseline's trusted range.
  public var inRange: Bool
  /// When both had the same reference scenario: the delta after dividing each median by its reference's, which
  /// takes out how fast the Mac ran in those minutes.
  public var referenceScenario: String?
  public var normalisedDeltaPct: Double?
  public var sameFixture: Bool
}

public enum Measure {
  /// A number as the text prints it (Explain's format).
  public static func number(_ x: Double?) -> String { Explain.fmt(x) }

  /// The trusted reps' numbers and what the others were.
  public static func summary(_ reps: [MeasureRep]) -> MeasureSummary {
    var s = MeasureSummary()
    s.failed = reps.filter { $0.failure != nil }.count
    s.ran = reps.count - s.failed
    let ok = reps.filter(\.trusted)
    s.trusted = ok.count
    s.values = ok.compactMap(\.side.objective)
    if !s.values.isEmpty { s.median = Stats.round(Stats.median(s.values), 3); s.min = s.values.min(); s.max = s.values.max() }
    let h = ok.compactMap(\.side.hitchTimeRatioMsPerS), l = ok.compactMap(\.side.longestStretchMs)
    if !h.isEmpty { s.hitchTimeRatioMsPerS = Stats.round(Stats.median(h), 2) }
    if !l.isEmpty { s.longestStretchMs = Stats.round(Stats.median(l), 2) }
    s.untrusted = untrustedSummary(reps)
    s.deterministic = deterministic(reps)
    for r in ok {
      for c in r.side.checksFailed where !s.checksFailed.contains(c) { s.checksFailed.append(c) }
      for g in r.side.guards ?? [] where !g.pass && g.name != GuardNames.snapshotDiff && !s.guardsFailed.contains(g.name) { s.guardsFailed.append(g.name) }
    }
    return s
  }

  /// "2/5 reps untrusted: not quiet ×2 (busy up to 99.8 %: swift-build); no frames (…) ×1"; nil when every rep that
  /// ran could be trusted.
  public static func untrustedSummary(_ reps: [MeasureRep]) -> String? {
    let ran = reps.filter { $0.failure == nil }
    var n = 0, notQuiet = 0, busiest: Double?, names: [String] = [], other: [(String, Int)] = []
    func count(_ k: String) { if let i = other.firstIndex(where: { $0.0 == k }) { other[i].1 += 1 } else { other.append((k, 1)) } }
    for r in ran where r.untrusted != nil {
      n += 1
      let s = r.side
      if s.quiet == false {
        notQuiet += 1
        if let b = s.busyPct { busiest = Swift.max(busiest ?? b, b) }
        for x in s.busy ?? [] where !names.contains(x) { names.append(x) }
      }
      if s.noFrames == true { count(Acceptance.noFramesPhrase) }
      if s.trustworthy == false { count(Acceptance.windowPhrase(s)) }
      if s.exit == 5 && s.quiet != false && s.trustworthy != false && s.noFrames != true { count("exit 5 (the bench's own untrusted)") }
      if s.profiled == true { count("a profiler was attached") }
    }
    guard n > 0 else { return nil }
    var parts: [String] = []
    if notQuiet > 0 {
      let d = [busiest.map { "busy up to \(Explain.fmt($0)) %" }, names.isEmpty ? nil : names.prefix(3).joined(separator: ", ")].compactMap { $0 }
      parts.append("not quiet ×\(notQuiet)" + (d.isEmpty ? "" : " (" + d.joined(separator: ": ") + ")"))
    }
    parts += other.map { "\($0.0) ×\($0.1)" }
    return "\(n)/\(ran.count) reps untrusted: " + parts.joined(separator: "; ")
  }

  /// Every untrusted rep (two or more) had its window wrong the same way and nothing else wrong: the build keeps the
  /// keyboard (or the window) somewhere else, and a rerun won't change it.
  public static func deterministic(_ reps: [MeasureRep]) -> String? {
    let bad = reps.filter { $0.failure == nil && $0.untrusted != nil }
    guard bad.count >= 2, bad.allSatisfy({ $0.side.trustworthy == false && $0.side.quiet != false && $0.side.noFrames != true }),
          let first = bad.first, bad.allSatisfy({ $0.side.windowFailed == first.side.windowFailed }) else { return nil }
    return "deterministic: \(Acceptance.windowPhrase(first.side)) in all \(bad.count) untrusted reps: a rerun won't change it"
  }

  /// Whether a rep's next attempt could come out differently: not when its window is wrong exactly as an earlier
  /// rep's was (and nothing else is wrong).
  public static func worthRedoing(_ r: MeasureRep, after earlier: [MeasureRep]) -> Bool {
    if r.failure != nil { return !(r.failure ?? "").hasPrefix("ran fixture") }
    guard r.untrusted != nil else { return false }
    let windowOnly = r.side.trustworthy == false && r.side.quiet != false && r.side.noFrames != true
    return !(windowOnly && earlier.contains { $0.side.trustworthy == false && $0.side.windowFailed == r.side.windowFailed })
  }

  /// Whether a rep ran a fixture other than the one asked for (compared by name: `crew@agents=24` is `crew`), as
  /// "ran fixture X, asked for Y"; nil when it says nothing or agrees.
  public static func fixtureMismatch(_ s: Side, asked: String) -> String? {
    guard let ran = s.fixture, Manifest.fixtureBase(ran) != Manifest.fixtureBase(asked) else { return nil }
    return "ran fixture \(ran), asked for \(asked): the adapter didn't run the fixture it was given (ADAPTER.md §3)"
  }

  /// A run against the scenario's baseline; nil when either has no trusted median.
  public static func compare(_ s: MeasureSummary, fixture: String, reference r: MeasureReference?, with b: BaselineRecord) -> BaselineComparison? {
    guard let m = s.median, b.median != 0 else { return nil }
    var c = BaselineComparison(measurement: b.measurement, build: b.build, median: b.median, min: b.min, max: b.max,
                               deltaPct: Stats.round((m - b.median) / abs(b.median) * 100, 1), inRange: m >= b.min && m <= b.max,
                               sameFixture: Manifest.fixtureBase(fixture) == Manifest.fixtureBase(b.fixture))
    if let r, r.scenario == b.referenceScenario, let rm = r.summary.median, let bm = b.referenceMedian, rm > 0, bm > 0 {
      c.referenceScenario = r.scenario
      c.normalisedDeltaPct = Stats.round(((m / rm) / (b.median / bm) - 1) * 100, 1)
    }
    return c
  }

  // MARK: text

  /// The measurement as text for an agent: what ran, the trusted numbers (or UNTRUSTED and why, never a number that
  /// looks fine), the checks, where the time went, the reference and the baseline, and the next step.
  public static func text(_ m: ScenarioRun, store: String? = nil) -> String {
    var o: [String] = []
    let s = m.summary
    o.append("\(m.kind) \(m.id) · \(m.scenario) on \(m.fixture)\(fixtureNote(m)) · \(m.target) [\(m.build.line)] · \(m.reps.count) rep(s)" + (m.runner.map { " on \($0.line)" } ?? ""))
    if let k = m.knobs, !k.isEmpty { o.append("knobs: " + k.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")) }
    if let l = Looks.key(m.params) { o.append("look: \(l) (its baseline and reference picture are this look's own)") }
    o.append(numbers(m.metric, s))
    if s.trusted > 0 {
      var f: [String] = []
      if let h = s.hitchTimeRatioMsPerS { f.append("hitch \(Explain.fmt(h)) ms/s") }
      if let l = s.longestStretchMs { f.append("longest stretch \(Explain.fmt(l)) ms") }
      if !f.isEmpty { o.append("  frames: " + f.joined(separator: ", ")) }
      o.append(s.checksFailed.isEmpty && s.guardsFailed.isEmpty ? "  checks: all passed" : "  FAILED: " + (s.checksFailed.map { "check \($0)" } + s.guardsFailed.map { "guard \($0)" }).joined(separator: ", "))
      if let w = m.reps.filter(\.trusted).compactMap(\.side.worstStretch).max(by: { $0.durationMs < $1.durationMs }) {
        o.append("  worst stretch: \(Explain.fmt(w.durationMs)) ms" + (w.step.map { " in \($0)" } ?? ""))
        if !w.topOurs.isEmpty { o.append("    ours: " + w.topOurs.joined(separator: "; ")) }
        if !w.topFramework.isEmpty { o.append("    framework: " + w.topFramework.joined(separator: "; ")) }
        if let c = w.causes { o.append("    causes: " + c) }
      }
    }
    if let d = s.deterministic { o.append("  · " + d) }
    let ran = m.reps.filter { $0.failure == nil }
    if !ran.isEmpty, !ran.contains(where: { [$0.side.exit != nil, $0.side.trustworthy != nil, $0.side.quiet != nil].contains(true) }) {
      o.append("  trust: not checked: the adapter reports no exit code, window or quiet state per rep (ADAPTER.md §3), so an untrusted rep would count")
    }
    for r in m.reps { o.append("  " + repLine(r, m.metric)) }
    if let r = m.reference {
      var line = "reference \(r.scenario) on the champion \(r.experiment) (\(r.fixture)), the same minutes: " + numbers(r.metric, r.summary).trimmingCharacters(in: .whitespaces)
      if let now = r.summary.median, let then = r.championObjective, then > 0 {
        let d = Stats.round((now - then) / then * 100, 1)
        line += "; its full stage had \(Explain.fmt(then)): this Mac runs \(abs(d) < 3 ? "about as it did then" : "\(Explain.fmt(abs(d))) % \(d > 0 ? "slower" : "faster") than then")"
      }
      o.append(line)
      for x in r.reps where !x.trusted { o.append("  " + repLine(x, r.metric)) }
    }
    if let c = m.againstBaseline {
      var line = "against the baseline \(c.measurement) [\(c.build.line)]: \(Explain.fmt(c.median)) (\(Explain.fmt(c.min))–\(Explain.fmt(c.max))) → \(Explain.fmt(s.median)), \(c.deltaPct > 0 ? "+" : "")\(Explain.fmt(c.deltaPct)) %, \(c.inRange ? "inside" : "outside") its range"
      if let n = c.normalisedDeltaPct, let rs = c.referenceScenario { line += "; \(n > 0 ? "+" : "")\(Explain.fmt(n)) % against the reference \(rs)" }
      if !c.sameFixture { line += " (another fixture: not comparable)" }
      o.append(line + ". Information, not a verdict: other minutes, not interleaved")
    }
    if let g = m.snapshot {
      let declared = (g.looks ?? []).contains { $0.expected == true }
      o.append("snapshot against the baseline's: \(g.pass ? (declared ? "changed where declared" : "same") : g.review == true ? "REVIEW" : "DIFFERENT") · \(g.detail)" + (g.artifacts.isEmpty ? "" : " · " + g.artifacts.joined(separator: ", ")))
      o += Looks.lines(g, indent: "  ")
    }
    for n in m.notes { o.append("note: " + n) }
    if let st = store { o.append("result: \(st)") }
    if let n = m.next { o.append("next: " + n) }
    return o.joined(separator: "\n") + "\n"
  }

  static func fixtureNote(_ m: ScenarioRun) -> String {
    guard let e = m.expectedFixture, Manifest.fixtureBase(e) != Manifest.fixtureBase(m.fixture) else { return m.expectedFixture != nil ? " (the scenario's own fixture)" : "" }
    return " (the scenario's own is \(e))"
  }

  /// The headline: trusted numbers only. With none, UNTRUSTED and why, and no number at all.
  static func numbers(_ metric: String, _ s: MeasureSummary) -> String {
    guard let med = s.median else {
      if s.ran == 0 { return "  \(metric): no rep ran (\(s.failed) failed)" }
      return "  \(metric): UNTRUSTED: 0/\(s.ran) reps trusted (\(s.untrusted ?? "untrusted reps")): no number to quote"
    }
    var t = "  \(metric): \(Explain.fmt(med)) median"
    if s.trusted > 1, let a = s.min, let b = s.max { t += " (\(Explain.fmt(a))–\(Explain.fmt(b)))" }
    t += ", \(s.trusted)/\(s.ran) reps trusted"
    if let u = s.untrusted { t += "; left out: " + u }
    if s.failed > 0 { t += "; \(s.failed) rep(s) failed" }
    return t
  }

  static func repLine(_ r: MeasureRep, _ metric: String) -> String {
    let head = "rep \(r.index + 1)" + (r.order.map { " (\($0) the reference)" } ?? "") + ": "
    let redo = r.redone.map { " (redone once: \($0))" } ?? ""
    if let f = r.failure { return head + "failed: " + f + redo }
    // An untrusted rep's value is shown so the record is whole, never as a number to quote.
    if let u = r.untrusted { return head + "UNTRUSTED (\(u)); its \(Explain.fmt(r.side.objective)) is not a number to quote" + redo }
    return head + Explain.fmt(r.side.objective) + (r.side.checksFailed.isEmpty ? "" : " · checks failed: " + r.side.checksFailed.joined(separator: ", ")) + redo
  }
}

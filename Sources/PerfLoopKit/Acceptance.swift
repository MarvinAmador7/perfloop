import Foundation

/// The acceptance rule of SPEC §5.1, as pure functions over pairs: a screen (3 pairs, a filter) and a full (5 + 5,
/// extended to 8 + 8 and 10 + 10 while "unknown"), both on interleaved, counterbalanced pairs. Guards veto: an
/// objective win with a failed guard is not a win.
public enum Acceptance {
  public static let screenPairs = 3
  /// Pairs per side at each look of the full stage: 5, then 8, then 10, then stop as "no decision".
  public static let fullLooks = [5, 8, 10]
  public static let alpha = 0.05
  /// 0.05 ≤ p < this is "unknown" (Pinpoint's word): measure more rather than decide.
  public static let unknownBelow = 0.2
  /// A gain smaller than this is never worth a promotion, whatever the band says (SPEC §5.1).
  public static let minGainPct = 5.0

  /// Smallest change worth calling, per metric: a share of the champion's median and an absolute floor in the
  /// metric's units (DeskBenchKit/Objective.swift's floors, kept).
  public static func floors(_ metric: String) -> (pct: Double, absolute: Double) {
    switch metric {
    case "mainThreadCpuMsPerStep": (5, 0.5)
    case "instructionsPerStep": (5, 0)
    case "latencyMs": (15, 3)
    case "hitchTimeRatioMsPerS": (25, 2)
    case "longestStretchMs": (25, 4)
    default: (10, 0)
    }
  }

  /// Why a pair can't decide anything (it is re-run on resume), or nil when it can.
  public static func unusable(_ p: Pair) -> String? {
    if let f = p.failure { return f }
    if p.a.objective == nil || p.b.objective == nil { return "the objective is missing on \(p.a.objective == nil ? "the champion" : "the candidate")" }
    if p.a.profiled == true || p.b.profiled == true { return "a profiler was attached: profiled runs never feed the objective" }
    if p.a.trustworthy == false || p.b.trustworthy == false { return "the window was not active, key and unoccluded: rerun" }
    if p.interrupted == true { return "interrupted: input during the rep (redo it)" }
    return nil
  }

  /// Correctness guards: a check the candidate fails while the champion passes it in the same pair, and a guard the
  /// candidate fails (or drops) that the champion passes (Guards.swift). `guards` are the champion manifest's names
  /// for the scenario ("checks" = all of its checks), never the candidate's.
  public static func guardFailures(_ pairs: [Pair], guards: [String]) -> [String] {
    var out: [String] = []
    for p in pairs where p.failure == nil {
      for c in p.b.checksFailed where !p.a.checksFailed.contains(c) && (guards.isEmpty || guards.contains("checks") || guards.contains(c)) {
        out.append("\(c) failed on the candidate in pair \(p.index + 1) (passed on the champion)")
      }
      out += guardResultFailures(p, guards: guards)
    }
    return out
  }

  /// Screen: promising when the candidate wins every pair, the median per-pair gain is ≥ max(5 %, band), and no
  /// guard failed. Three pairs can't reach significance (sign test p = 0.125): this filters, it doesn't decide.
  public static func screen(_ pairs: [Pair], metric: String, guards: [String]) -> Stage {
    var st = base(pairs, metric: metric, guards: guards)
    if let m = RunnerIdentity.mixed(pairs) { st.verdict = "error"; st.reasons = [m]; return st }
    let use = pairs.filter { unusable($0) == nil }
    guard !use.isEmpty else { st.verdict = "error"; st.reasons = ["no pair produced the objective \(metric)"] + pairs.compactMap(unusable); return st }
    let gains = use.map { gainPct($0.a.objective!, $0.b.objective!) }
    let med = Stats.round(Stats.median(gains), 2), threshold = max(minGainPct, st.band ?? 0)
    st.medianGainPct = med
    st.signP = SignTest.p(wins: st.wins, losses: use.filter { $0.b.objective! > $0.a.objective! }.count)
    var r: [String] = []
    if st.wins < use.count { r.append("the candidate won \(st.wins) of \(use.count) pairs (a screen needs all)") }
    if med < threshold { r.append("median gain \(med) % is under max(\(Int(minGainPct)) %, band \(st.band ?? 0) %)") }
    if !st.guardsPassed { r += st.guardFailures }
    let reviews = st.guardReviews ?? []
    r += reviews.map { "needs review: " + $0 }
    if use.count < pairs.count { r.append("\(pairs.count - use.count) pair(s) unusable: " + pairs.compactMap(unusable).joined(separator: "; ")) }
    // Three pairs can't call a regression either: a screen only filters. "Slower in every pair" is said, not judged.
    if st.wins == 0 && -med > (st.band ?? 0) { r.append("slower in every pair (median \(med) %): a full would be needed to call it a regression") }
    st.verdict = r.count == reviews.count && use.count >= screenPairs ? (reviews.isEmpty ? "promising" : "needsReview") : "rejected"
    if st.verdict != "rejected" { r.append("won \(st.wins)/\(use.count) pairs, median gain \(med) % ≥ \(threshold) %") }
    st.reasons = r
    return st
  }

  /// Full: won when Mann-Whitney U gives p < 0.05, the effect is ≥ the band (and ≥ 5 %), and the frame guards
  /// (hitch time ratio, longest stretch) are not worse beyond their bands; "unknown" for 0.05 ≤ p < 0.2 (extend), which
  /// becomes "noDecision" at the last look; lost otherwise. `regression` only when the candidate is significantly
  /// worse beyond the band: a same-build comparison is never one.
  public static func full(_ pairs: [Pair], metric: String, guards: [String], lastLook: Bool) -> Stage {
    var st = base(pairs, metric: metric, guards: guards)
    if let m = RunnerIdentity.mixed(pairs) { st.verdict = "error"; st.reasons = [m]; return st }
    let use = pairs.filter { unusable($0) == nil }
    st.repsPerSide = use.count
    guard use.count >= 2 else { st.verdict = "error"; st.reasons = ["fewer than 2 usable pairs"] + pairs.compactMap(unusable); return st }
    let a = use.map { $0.a.objective! }, b = use.map { $0.b.objective! }
    let mwu = MannWhitney.test(a, b)
    let effect = Stats.round(gainPct(Stats.median(a), Stats.median(b)), 2), band = st.band ?? 0
    st.mwuP = mwu.p; st.effectPct = effect; st.medianGainPct = effect
    st.signP = SignTest.p(wins: st.wins, losses: use.filter { $0.b.objective! > $0.a.objective! }.count)
    // Frame guards: not worse than the champion beyond their own bands, whatever the objective did.
    var fg: [String: FrameGuard] = [:]
    for (name, pick) in [("hitchTimeRatioMsPerS", { (s: Side) in s.hitchTimeRatioMsPerS }), ("longestStretchMs", { (s: Side) in s.longestStretchMs })] where name != metric {
      let xa = use.compactMap { pick($0.a) }, xb = use.compactMap { pick($0.b) }
      guard xa.count == use.count, xb.count == use.count else { continue }
      let f = floors(name), bd = Band(champion: xa, candidate: xb, floorPct: f.pct, absoluteFloor: f.absolute)
      fg[name] = FrameGuard(a: Stats.median(xa), b: Stats.median(xb), bandPct: bd.pct, pass: Stats.median(xb) - Stats.median(xa) <= bd.width)
    }
    st.frameGuards = fg
    let frameFailed = fg.filter { !$0.value.pass }.keys.sorted()
    var r: [String] = ["\(use.count) + \(use.count): Mann-Whitney p = \(mwu.p)\(mwu.exact ? " (exact)" : ""), effect \(effect) % (band \(band) %)"]
    st.regression = mwu.p < alpha && -effect >= band
    if mwu.p < alpha {
      if effect >= max(band, minGainPct) && st.guardsPassed && frameFailed.isEmpty {
        // A snapshot unlike the champion's is never a win: the owner looks first (C6).
        st.verdict = (st.guardReviews ?? []).isEmpty ? "won" : "needsReview"
        r += (st.guardReviews ?? []).map { "needs review: " + $0 }
      }
      else {
        st.verdict = "lost"
        if effect < 0 { r.append(st.regression == true ? "the candidate is slower beyond the band" : "the candidate is slower, inside the band") }
        else if effect < max(band, minGainPct) { r.append("significant, but \(effect) % is under max(band \(band) %, \(Int(minGainPct)) %)") }
        if !st.guardsPassed { r += st.guardFailures }
        for f in frameFailed { r.append("frame guard \(f): \(fg[f]!.a) → \(fg[f]!.b), worse beyond its ±\(fg[f]!.bandPct) % band") }
      }
    } else if mwu.p < unknownBelow {
      st.verdict = lastLook ? "noDecision" : "unknown"
      r.append(lastLook ? "still unknown at \(use.count) + \(use.count): no decision (the owner decides, or drop it)" : "unknown: extend")
    } else {
      st.verdict = "lost"; r.append("no difference the test can see (p ≥ \(unknownBelow))")
    }
    st.reasons = r
    return st
  }

  /// The second fixture's screen after a win: not worse means the median gain is above −band (SPEC §5.5).
  public static func notWorse(_ pairs: [Pair], metric: String, guards: [String]) -> (Stage, Bool) {
    var st = screen(pairs, metric: metric, guards: guards)
    let ok = st.verdict != "error" && (st.medianGainPct ?? -100) > -(st.band ?? 0) && st.guardsPassed && (st.guardReviews ?? []).isEmpty
    st.reasons.append(ok ? "not worse on this fixture" : "worse on this fixture beyond the band, or a guard failed")
    return (st, ok)
  }

  /// (champion − candidate) / champion, in %: positive is a gain (lower is better).
  public static func gainPct(_ a: Double, _ b: Double) -> Double { a == 0 ? (b == 0 ? 0 : -100) : (a - b) / abs(a) * 100 }

  static func base(_ pairs: [Pair], metric: String, guards: [String]) -> Stage {
    var st = Stage(metric: metric, pairs: pairs, verdict: "pending")
    st.runner = pairs.first(where: { $0.failure == nil })?.runner ?? pairs.first?.runner
    let use = pairs.filter { unusable($0) == nil }
    let a = use.map { $0.a.objective! }, b = use.map { $0.b.objective! }
    st.objective = ["a": a, "b": b]
    st.wins = use.filter { $0.b.objective! < $0.a.objective! }.count
    let f = floors(metric)
    if !a.isEmpty { st.band = Band(champion: a, candidate: b, floorPct: f.pct, absoluteFloor: f.absolute).pct }
    st.guardFailures = guardFailures(pairs, guards: guards); st.guardsPassed = st.guardFailures.isEmpty
    let reviews = guardReviews(pairs, guards: guards); st.guardReviews = reviews.isEmpty ? nil : reviews
    return st
  }
}

/// SPEC §5.3: when to stop climbing a scenario.
public struct StopInput: Sendable {
  public var session: [LedgerEntry]
  public var now: Date
  /// The SPEC §1 budget verdict on the champion with 5 + 5 reps on hardware, when known.
  public var budgetPassed: Bool?
  /// The largest attributable subtree as a share of the objective, when a profile says.
  public var largestAttributablePct: Double?
  public var timeBudgetS: Double = 7200
  public var maxCandidates = 20
  public var maxNonPromisingStreak = 5
  public var minSubtreePct = 5.0
  public init(session: [LedgerEntry], now: Date = Date(), budgetPassed: Bool? = nil, largestAttributablePct: Double? = nil) {
    self.session = session; self.now = now; self.budgetPassed = budgetPassed; self.largestAttributablePct = largestAttributablePct
  }
}

public enum Stopping {
  /// Every rule that holds; empty means keep going.
  public static func reasons(_ i: StopInput) -> [String] {
    var r: [String] = []
    if i.budgetPassed == true { r.append("the champion meets its SPEC §1 budget") }
    if let s = i.largestAttributablePct, s < i.minSubtreePct { r.append("no attributable subtree ≥ \(Int(i.minSubtreePct)) % of the objective remains (largest \(s) %)") }
    let screens = i.session.filter { $0.state == ExpState.promising.rawValue || $0.state == ExpState.rejected.rawValue }
    let streak = screens.reversed().prefix { $0.state == ExpState.rejected.rawValue }.count
    if streak >= i.maxNonPromisingStreak { r.append("\(streak) non-promising candidates in a row") }
    let candidates = Set(i.session.filter { $0.state == ExpState.built.rawValue }.map(\.experiment)).count
    if candidates >= i.maxCandidates { r.append("\(candidates) candidates this session (budget \(i.maxCandidates))") }
    if let first = i.session.first.flatMap({ Clock.date($0.at) }), i.now.timeIntervalSince(first) >= i.timeBudgetS {
      r.append("the session's time budget (\(Int(i.timeBudgetS / 60)) min) is spent")
    }
    return r
  }
}

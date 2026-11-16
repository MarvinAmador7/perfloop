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
    // A replayed gesture (C9): both sit at 0 on a main thread that keeps up, so their bands are absolute.
    case "positionErrorP95Pt": (25, 0.5)
    case "stalls": (25, 1)
    default: (10, 0)
    }
  }

  /// Why a pair can't decide anything (it is re-run on resume), or nil when it can.
  public static func unusable(_ p: Pair) -> String? {
    if let f = p.failure { return f }
    // A side that drew no frame has no frame metric to be the objective: that is untrusted (below), not missing.
    if (p.a.objective == nil && p.a.noFrames != true) || (p.b.objective == nil && p.b.noFrames != true) { return "the objective is missing on \(p.a.objective == nil ? "the champion" : "the candidate")" }
    if p.a.profiled == true || p.b.profiled == true { return "a profiler was attached: profiled runs never feed the objective" }
    if let u = untrusted(p) { return u }
    if p.interrupted == true { return "interrupted: input during the rep (redo it)" }
    return nil
  }

  // MARK: trust

  /// Why one side's rep can't be trusted, as short phrases (empty: it can): its window was wrong (and which fields),
  /// the machine wasn't quiet when it started, or the bench itself said so (exit 5). Such a rep never decides.
  public static func distrust(_ s: Side) -> [String] {
    var r: [String] = []
    if s.noFrames == true { r.append(noFramesPhrase) }
    if s.trustworthy == false { r.append(windowPhrase(s)) }
    if s.quiet == false { r.append(busyPhrase(s)) }
    if s.exit == 5 && r.isEmpty { r.append("the bench exited 5 (untrusted)") }
    return r
  }

  /// A rep that presented no frame (Readings.noFrames): its frame metrics are missing, not 0.
  static let noFramesPhrase = "no frames (screen locked or window off-screen)"

  static func windowPhrase(_ s: Side) -> String {
    guard let f = s.windowFailed, !f.isEmpty else { return "window not active, key, visible and unoccluded" }
    return "window " + f.map { "\($0)=\($0 == "occluded")" }.joined(separator: ", ")
  }

  static func busyPhrase(_ s: Side) -> String {
    let d = [s.busyPct.map { "busy \(Explain.fmt($0)) %" }, s.busy.flatMap { $0.isEmpty ? nil : $0.prefix(3).joined(separator: ", ") }].compactMap { $0 }
    return "not quiet" + (d.isEmpty ? "" : " (" + d.joined(separator: ": ") + ")")
  }

  /// Why a pair can't be trusted, naming the side and what was wrong; nil when both reps can be.
  public static func untrusted(_ p: Pair) -> String? {
    let a = distrust(p.a), b = distrust(p.b)
    if a.isEmpty && b.isEmpty { return nil }
    if a == b { return "untrusted on both sides: " + a.joined(separator: "; ") }
    if a.isEmpty { return "untrusted on the candidate: " + b.joined(separator: "; ") + " (the champion's rep was fine)" }
    if b.isEmpty { return "untrusted on the champion: " + a.joined(separator: "; ") + " (the candidate's rep was fine)" }
    return "untrusted on the champion: " + a.joined(separator: "; ") + "; on the candidate: " + b.joined(separator: "; ")
  }

  /// A pair that ran and has numbers, but whose reps can't be trusted: redone once, and never decides.
  public static func distrusted(_ p: Pair) -> Bool {
    p.failure == nil && p.interrupted != true && (p.a.objective != nil || p.a.noFrames == true) && (p.b.objective != nil || p.b.noFrames == true) && p.a.profiled != true && p.b.profiled != true && untrusted(p) != nil
  }

  /// One side's window was wrong while the other side's was right: the build's state, not the machine's.
  static func oneSidedWindow(_ p: Pair) -> String? {
    if p.a.trustworthy == false && p.b.trustworthy == true { return "the champion's \(windowPhrase(p.a))" }
    if p.b.trustworthy == false && p.a.trustworthy == true { return "the candidate's \(windowPhrase(p.b))" }
    return nil
  }

  /// Untrusted pairs a rerun can't fix: every one has the same side's window wrong the same way while the other side's
  /// was right, in both orders (so it isn't whichever ran second). The build keeps the keyboard somewhere else.
  public static func deterministic(_ pairs: [Pair]) -> String? {
    let bad = pairs.filter(distrusted)
    guard let sig = bad.first.flatMap(oneSidedWindow), bad.allSatisfy({ oneSidedWindow($0) == sig }), Set(bad.map(\.order)).count > 1 else { return nil }
    return "deterministic: \(sig) in all \(bad.count) untrusted pairs, in both orders, while the other side's was right: a rerun won't change it"
  }

  /// How many of a stage's reps couldn't be trusted, and why ("6/6 reps untrusted: not quiet ×6 (busy up to 99.8 %:
  /// swift-build)"); nil when every rep could. Counts the pairs that ran (a failed pair has no reps to judge).
  public static func untrustedSummary(_ pairs: [Pair]) -> String? {
    let ran = pairs.filter { $0.failure == nil && $0.interrupted != true }
    var reps = 0, notQuiet = 0, busiest: Double?, names: [String] = [], other: [(String, Int)] = []
    func count(_ k: String) { if let i = other.firstIndex(where: { $0.0 == k }) { other[i].1 += 1 } else { other.append((k, 1)) } }
    for p in ran {
      for (who, s) in [("champion", p.a), ("candidate", p.b)] where !distrust(s).isEmpty {
        reps += 1
        if s.quiet == false {
          notQuiet += 1
          if let b = s.busyPct { busiest = max(busiest ?? b, b) }
          for n in s.busy ?? [] where !names.contains(n) { names.append(n) }
        }
        if s.noFrames == true { count(noFramesPhrase) }
        if s.trustworthy == false { count("the \(who)'s \(windowPhrase(s))") }
        if s.exit == 5 && s.quiet != false && s.trustworthy != false { count("exit 5 (the bench's own untrusted)") }
      }
    }
    guard reps > 0 else { return nil }
    var parts: [String] = []
    if notQuiet > 0 {
      let d = [busiest.map { "busy up to \(Explain.fmt($0)) %" }, names.isEmpty ? nil : names.prefix(3).joined(separator: ", ")].compactMap { $0 }
      parts.append("not quiet ×\(notQuiet)" + (d.isEmpty ? "" : " (" + d.joined(separator: ": ") + ")"))
    }
    parts += other.map { "\($0.0) ×\($0.1)" }
    return "\(reps)/\(ran.count * 2) reps untrusted: " + parts.joined(separator: "; ")
  }

  /// A stage that can't decide because pairs it needs are untrusted: says how many and why, and whether a rerun helps.
  static func untrustedStage(_ st: Stage, _ pairs: [Pair], use: [Pair]) -> Stage {
    var st = st
    st.verdict = "untrusted"
    st.reasons = [st.untrusted ?? "untrusted reps"]
    if let d = deterministic(pairs) { st.reasons.append(d) }
    else {
      st.reasons.append("\(pairs.filter(distrusted).count) pair(s) still untrusted after a redo, \(use.count) trusted: a rerun on a quiet Mac measures only the untrusted pairs again")
    }
    return st
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
    // Untrusted pairs never decide: unless the trusted ones already reject the candidate on their own (a pair it didn't
    // win, a guard it failed), the screen waits for them to be measured again.
    if pairs.contains(where: distrusted), !use.contains(where: { $0.b.objective! >= $0.a.objective! }), guardFailures(use, guards: guards).isEmpty {
      return untrustedStage(st, pairs, use: use)
    }
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
  /// (hitch time ratio, longest stretch; for a replayed gesture also its position error and stalls, C9) are not worse
  /// beyond their bands; "unknown" for 0.05 ≤ p < 0.2 (extend), which
  /// becomes "noDecision" at the last look; lost otherwise. `regression` only when the candidate is significantly
  /// worse beyond the band: a same-build comparison is never one.
  public static func full(_ pairs: [Pair], metric: String, guards: [String], lastLook: Bool) -> Stage {
    var st = base(pairs, metric: metric, guards: guards)
    if let m = RunnerIdentity.mixed(pairs) { st.verdict = "error"; st.reasons = [m]; return st }
    let use = pairs.filter { unusable($0) == nil }
    st.repsPerSide = use.count
    // The full decides on every pair of its look or not at all: an untrusted one is measured again first.
    if pairs.contains(where: distrusted) { return untrustedStage(st, pairs, use: use) }
    guard use.count >= 2 else { st.verdict = "error"; st.reasons = ["fewer than 2 usable pairs"] + pairs.compactMap(unusable); return st }
    let a = use.map { $0.a.objective! }, b = use.map { $0.b.objective! }
    let mwu = MannWhitney.test(a, b)
    let effect = Stats.round(gainPct(Stats.median(a), Stats.median(b)), 2), band = st.band ?? 0
    st.mwuP = mwu.p; st.effectPct = effect; st.medianGainPct = effect
    st.signP = SignTest.p(wins: st.wins, losses: use.filter { $0.b.objective! > $0.a.objective! }.count)
    // Frame guards: not worse than the champion beyond their own bands, whatever the objective did.
    var fg: [String: FrameGuard] = [:]
    // Jerk is never a guard: it differentiates three times and swings with the display link's jitter.
    let guarded: [(String, (Side) -> Double?)] = [("hitchTimeRatioMsPerS", \.hitchTimeRatioMsPerS), ("longestStretchMs", \.longestStretchMs),
                                                  ("positionErrorP95Pt", \.positionErrorP95Pt), ("stalls", \.stalls)]
    for (name, pick) in guarded where name != metric {
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
    if st.verdict == "untrusted" { return (st, false) }
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
    st.untrusted = untrustedSummary(pairs)
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

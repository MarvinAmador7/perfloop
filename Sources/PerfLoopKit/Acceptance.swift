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

  /// Pairs a screen takes at most, `exp screen --more` included: past them the full decides.
  public static let maxScreenPairs = 10

  /// The pairs out of `n` a promising screen must win: as strong as 3 of 3 (one-sided sign test p ≤ 0.125), so a
  /// screen grown with `--more` filters no more loosely than a 3-pair one (4 → 4, 6 → 5, 8 → 7, 10 → 8).
  public static func winsNeeded(_ n: Int) -> Int {
    guard n > 0 else { return 0 }
    return (0...n).first { SignTest.p(wins: $0, losses: n - $0) <= 0.125 } ?? n
  }

  /// Screen: promising when the candidate wins every pair (with `--more`, as many as `winsNeeded`), the median per-pair
  /// gain is ≥ max(5 %, band), and no guard failed. Three pairs can't reach significance (sign test p = 0.125): this
  /// filters, it doesn't decide. When it isn't promising, it is `rejected` only when the pairs say the idea can't win
  /// (a guard failed, slower in every pair, or even the one-sided 95 % high bound of the gain is under 5 %), and
  /// `inconclusive` when they can't tell (mixed signs or a band wider than the gain): more pairs or the full decide.
  public static func screen(_ pairs: [Pair], metric: String, guards: [String]) -> Stage {
    var st = base(pairs, metric: metric, guards: guards)
    if let m = RunnerIdentity.mixed(pairs) { st.verdict = "error"; st.reasons = [m]; return st }
    let use = pairs.filter { unusable($0) == nil }
    // Untrusted pairs never decide: unless a trusted pair already rejects the candidate on its own (a guard it failed),
    // the screen waits for them to be measured again.
    if pairs.contains(where: distrusted), guardFailures(use, guards: guards).isEmpty {
      return untrustedStage(st, pairs, use: use)
    }
    guard !use.isEmpty else { st.verdict = "error"; st.reasons = ["no pair produced the objective \(metric)"] + pairs.compactMap(unusable); return st }
    let gains = use.map { gainPct($0.a.objective!, $0.b.objective!) }
    let med = Stats.round(Stats.median(gains), 2), threshold = max(minGainPct, st.band ?? 0)
    let n = use.count, need = winsNeeded(max(n, screenPairs))
    st.medianGainPct = med
    st.signP = SignTest.p(wins: st.wins, losses: use.filter { $0.b.objective! > $0.a.objective! }.count)
    var r: [String] = []
    if st.wins < need { r.append("the candidate won \(st.wins) of \(n) pairs (a screen \(n <= screenPairs ? "needs all" : "of \(n) needs \(need)"))") }
    if med < threshold { r.append("median gain \(med) % is under max(\(Int(minGainPct)) %, band \(st.band ?? 0) %)") }
    if !st.guardsPassed { r += st.guardFailures }
    let reviews = st.guardReviews ?? []
    r += reviews.map { "needs review: " + $0 }
    if use.count < pairs.count { r.append("\(pairs.count - use.count) pair(s) unusable: " + pairs.compactMap(unusable).joined(separator: "; ")) }
    let ci = PairedT.bounds(gains)
    if r.count == reviews.count && n >= screenPairs {
      st.verdict = reviews.isEmpty ? "promising" : "needsReview"
      r.append("won \(st.wins)/\(n) pairs, median gain \(med) % ≥ \(threshold) %")
    } else if !st.guardsPassed {
      st.verdict = "rejected"
    } else if st.wins == 0 && n >= 2 {
      // Three pairs can't call a regression either: a screen only filters. "Slower in every pair" is said, not judged.
      st.verdict = "rejected"
      r.append("slower in every pair (median \(med) %)" + (-med > (st.band ?? 0) ? ": a full would be needed to call it a regression" : ""))
    } else if let hi = ci.high, hi < minGainPct {
      st.verdict = "rejected"
      r.append("even at best the gain is \(Stats.round(hi, 1)) % (one-sided 95 % bound of the mean \(Stats.round(ci.mean, 1)) %), under the \(Int(minGainPct)) % a promotion needs")
    } else {
      st.verdict = "inconclusive"
      let range = ci.low.flatMap { l in ci.high.map { "\(Stats.round(l, 1)) … \(Stats.round($0, 1)) %" } }
      r.append("can't tell: the gain could be " + (range.map { "anywhere in \($0) (90 % interval)" } ?? "anything (one pair can't bound it)") + ", around the \(Int(minGainPct)) % a promotion needs: add pairs (exp screen --more) or run the full")
    }
    st.reasons = r
    return st
  }

  /// Expect same (a feature or guard check, `exp new --expect same`): does the candidate cost nothing? A
  /// non-inferiority test per metric on the paired differences (`PairedT`): the objective, then each frame guard both
  /// sides report. `noRegression` when every metric's high bound is under its margin and no guard failed; `regressed`
  /// when a correctness guard failed or a metric's low bound is over its margin (worse beyond it, at 95 %);
  /// `inconclusive` otherwise: the interval straddles a margin, and more pairs narrow it. The margin is the metric's
  /// floor (`floors`: the smallest change worth calling), never the run's noise band, which a noisy Mac would widen
  /// until anything passed. A snapshot that differs is a "look", not a verdict: a feature changes what it shows.
  public static func same(_ pairs: [Pair], metric: String, guards: [String], lastLook: Bool) -> Stage {
    var st = base(pairs, metric: metric, guards: guards)
    if let m = RunnerIdentity.mixed(pairs) { st.verdict = "error"; st.reasons = [m]; return st }
    let use = pairs.filter { unusable($0) == nil }
    st.repsPerSide = use.count
    // A guard the candidate failed on a trusted pair is a regression whatever the rest say; anything else waits for
    // the untrusted pairs to be measured again.
    let failed = guardFailures(use, guards: guards)
    if pairs.contains(where: distrusted), failed.isEmpty { return untrustedStage(st, pairs, use: use) }
    guard !use.isEmpty else { st.verdict = "error"; st.reasons = ["no pair produced the objective \(metric)"] + pairs.compactMap(unusable); return st }
    st.medianGainPct = Stats.round(Stats.median(use.map { gainPct($0.a.objective!, $0.b.objective!) }), 2)
    st.signP = SignTest.p(wins: st.wins, losses: use.filter { $0.b.objective! > $0.a.objective! }.count)
    var costs = [cost(metric, use, \.objective)!]
    var unchecked: [String] = []
    for (name, pick) in frameMetrics where name != metric {
      if let c = cost(name, use, pick) { costs.append(c) } else if name == "hitchTimeRatioMsPerS" || name == "longestStretchMs" { unchecked.append(name) }
    }
    st.costs = costs
    let worse = costs.filter { $0.call == "worse" }, unsure = costs.filter { $0.call == "unsure" }
    var r: [String] = failed
    r += worse.map { "\($0.metric) is worse beyond its margin: \($0.text)" }
    if !failed.isEmpty || !worse.isEmpty {
      st.verdict = "regressed"; st.regression = !worse.isEmpty
    } else if unsure.isEmpty {
      st.verdict = "noRegression"
      r.append("no cost beyond the margin on " + costs.map(\.metric).joined(separator: ", ") + " (\(use.count) pairs)")
    } else {
      st.verdict = "inconclusive"
      r += unsure.map { "can't tell on \($0.metric): \($0.text)" }
      r.append(lastLook ? "still inconclusive at \(use.count) + \(use.count): this runner can't resolve a change that small" : "add pairs: the interval narrows with them")
    }
    if !unchecked.isEmpty { r.append("not checked: \(unchecked.joined(separator: ", ")) (the adapter reports none per side)") }
    r += (st.guardReviews ?? []).map { "look: " + $0 }
    if use.count < pairs.count { r.append("\(pairs.count - use.count) pair(s) unusable: " + pairs.compactMap(unusable).joined(separator: "; ")) }
    st.reasons = r
    return st
  }

  /// The frame metrics a full holds not worse (jerk never: it differentiates three times and swings with the display
  /// link's jitter), and an expect-same stage holds to its margin.
  static let frameMetrics: [(String, (Side) -> Double?)] = [("hitchTimeRatioMsPerS", \.hitchTimeRatioMsPerS), ("longestStretchMs", \.longestStretchMs),
                                                           ("positionErrorP95Pt", \.positionErrorP95Pt), ("stalls", \.stalls)]

  /// What the candidate costs on one metric over the pairs, held to the metric's floor; nil unless both sides report
  /// it in every pair.
  static func cost(_ metric: String, _ use: [Pair], _ pick: (Side) -> Double?) -> CostBound? {
    let xa = use.compactMap { pick($0.a) }, xb = use.compactMap { pick($0.b) }
    guard !use.isEmpty, xa.count == use.count, xb.count == use.count else { return nil }
    let ci = PairedT.bounds(zip(xa, xb).map { $1 - $0 })
    let f = floors(metric), champion = Stats.median(xa)
    let margin = max(abs(champion) * f.pct / 100, f.absolute)
    let call = ci.low.map { $0 > margin } == true ? "worse" : ci.high.map { $0 < margin } == true ? "same" : "unsure"
    func r(_ x: Double?) -> Double? { x.map { Stats.round($0, 4) } }
    return CostBound(metric: metric, champion: Stats.round(champion, 4), change: Stats.round(ci.mean, 4), low: r(ci.low), high: r(ci.high), margin: Stats.round(margin, 4), call: call)
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
    for (name, pick) in frameMetrics where name != metric {
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
  /// From the first optimisation experiment, expect-same stages not counted (`Stopping.budgetClock`).
  public var timeBudgetS: Double = 7200
  public var maxCandidates = 20
  public var maxNonPromisingStreak = 5
  public var minSubtreePct = 5.0
  public init(session: [LedgerEntry], now: Date = Date(), budgetPassed: Bool? = nil, largestAttributablePct: Double? = nil) {
    self.session = session; self.now = now; self.budgetPassed = budgetPassed; self.largestAttributablePct = largestAttributablePct
  }
}

public enum Stopping {
  /// Every rule that holds; empty means keep going. They are the optimisation loop's: an expect-same experiment's lines
  /// (a feature or guard check) count toward none of them, and an inconclusive screen neither extends nor breaks the
  /// streak (it decided nothing). The time budget's clock starts at the session's first optimisation experiment and
  /// stops while expect-same stages run (`budgetClock`).
  public static func reasons(_ i: StopInput) -> [String] {
    var r: [String] = []
    if i.budgetPassed == true { r.append("the champion meets its SPEC §1 budget") }
    if let s = i.largestAttributablePct, s < i.minSubtreePct { r.append("no attributable subtree ≥ \(Int(i.minSubtreePct)) % of the objective remains (largest \(s) %)") }
    let session = i.session.filter { $0.expect != "same" }
    let screens = session.filter { $0.state == ExpState.promising.rawValue || $0.state == ExpState.rejected.rawValue }
    let streak = screens.reversed().prefix { $0.state == ExpState.rejected.rawValue }.count
    if streak >= i.maxNonPromisingStreak { r.append("\(streak) non-promising candidates in a row") }
    let candidates = Set(session.filter { $0.state == ExpState.built.rawValue }.map(\.experiment)).count
    if candidates >= i.maxCandidates { r.append("\(candidates) candidates this session (budget \(i.maxCandidates))") }
    if let c = budgetClock(i.session, now: i.now), c.spentS >= i.timeBudgetS {
      let feature = c.featureS >= 60 ? ", not counting \(Int(c.featureS / 60)) min of expect-same stages" : ""
      r.append("the session's time budget (\(Int(i.timeBudgetS / 60)) min) is spent: \(Int(c.spentS / 60)) min since its first optimisation experiment\(feature)")
    }
    return r
  }

  /// Lines that aren't an optimisation candidate's: the session's start, an owner's champion lines (set, merged),
  /// `perfloop run`'s and `perfloop baseline`'s measurements.
  static let notCandidates: Set<String> = ["session", ExpState.promoted.rawValue, "merged", "measure", "baseline"]

  /// The session's time budget so far: seconds from its first optimisation line (an experiment that isn't expect-same:
  /// its `built` line) to `now`, less the time expect-same stages ran after it (`featureS`). nil before that line: a
  /// session of feature checks alone never spends it. There is no per-stage timing; a stage's run is read from the
  /// ledger: an expect-same line (a screen's or full's verdict, a guards run) right after another line of the same
  /// experiment ran from that line to it. A `full` line marks a full's start, so the gap before it counts; and a line
  /// with another experiment's in between counts, so a stage's time is never subtracted from anything else's.
  public static func budgetClock(_ session: [LedgerEntry], now: Date) -> (spentS: Double, featureS: Double)? {
    guard let first = session.first(where: { $0.expect != "same" && !notCandidates.contains($0.state) }), let start = Clock.date(first.at) else { return nil }
    var feature = 0.0
    for (prev, cur) in zip(session, session.dropFirst()) where cur.expect == "same" && prev.experiment == cur.experiment && cur.state != ExpState.full.rawValue {
      guard let a = Clock.date(prev.at), let b = Clock.date(cur.at) else { continue }
      feature += max(0, b.timeIntervalSince(max(a, start)))
    }
    return (max(0, now.timeIntervalSince(start) - feature), feature)
  }
}

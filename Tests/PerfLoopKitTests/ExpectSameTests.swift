import XCTest
@testable import PerfLoopKit

/// Feature verification (b2, b3): the expect-same verdicts (no regression, regressed, inconclusive) by a non-inferiority
/// test against the metric's margin, and a screen that says it can't tell instead of rejecting.
final class ExpectSameTests: XCTestCase {
  let cpu = "mainThreadCpuMsPerStep"

  func testPairedTBounds() {
    let b = PairedT.bounds([1, 2, 3])                                    // mean 2, sd 1, t(2) = 2.920
    XCTAssertEqual(b.mean, 2); XCTAssertEqual(b.low!, 2 - 2.920 / 3.0.squareRoot(), accuracy: 1e-9); XCTAssertEqual(b.high!, 2 + 2.920 / 3.0.squareRoot(), accuracy: 1e-9)
    XCTAssertNil(PairedT.bounds([4]).high, "one pair bounds nothing")
    XCTAssertEqual(PairedT.bounds([]).n, 0)
    XCTAssertEqual(PairedT.t95(1), 6.314); XCTAssertEqual(PairedT.t95(9), 1.833); XCTAssertEqual(PairedT.t95(500), 1.697)
  }

  func testWinsNeededKeepsTheScreensStrength() {
    XCTAssertEqual([3, 4, 5, 6, 7, 8, 9, 10].map(Acceptance.winsNeeded), [3, 4, 5, 5, 6, 7, 7, 8])
  }

  // MARK: expect same

  func testASameBuildIsNeverARegression() {
    var no = 0
    for seed in UInt64(1)...200 {
      for n in [3, 10] {
        let s = Acceptance.same(pairs(n, a: 41.2, b: 41.2, seed: seed), metric: cpu, guards: ["checks"], lastLook: n == 10)
        XCTAssertNotEqual(s.verdict, "regressed", "seed \(seed), \(n) pairs: \(s.reasons)")
        XCTAssertNotEqual(s.regression, true)
        if n == 10 && s.verdict == "noRegression" { no += 1 }
      }
    }
    XCTAssertGreaterThanOrEqual(no, 180, "10 pairs at 3 % noise show a same build costs nothing ≥ 90 % of the time")
  }

  func testAQuietSameBuildCostsNothingInThreePairs() {
    let s = Acceptance.same(pairs(3, a: 41.2, b: 41.2, cv: 0.005, seed: 4), metric: cpu, guards: ["checks"], lastLook: false)
    XCTAssertEqual(s.verdict, "noRegression", "\(s.reasons)")
    XCTAssertEqual(s.costs?.map(\.metric), [cpu, "hitchTimeRatioMsPerS", "longestStretchMs"])
    XCTAssertTrue(s.costs!.allSatisfy { $0.call == "same" })
    XCTAssertEqual(s.costs?.first?.margin ?? 0, 41.2 * 0.05, accuracy: 0.05, "the margin is the metric's floor (5 % of CPU per step), not the band")
    XCTAssertTrue(s.reasons.contains { $0.hasPrefix("no cost beyond the margin on \(cpu), hitchTimeRatioMsPerS, longestStretchMs") }, "\(s.reasons)")
  }

  func testAFasterFeatureCostsNothingToo() {
    // Non-inferiority, not two-sided equivalence: a feature that happens to be faster costs nothing.
    XCTAssertEqual(Acceptance.same(pairs(3, a: 40, b: 20, cv: 0.01, seed: 2), metric: cpu, guards: [], lastLook: false).verdict, "noRegression")
  }

  func testAConsistentSlowdownIsARegressionWithItsSize() {
    let s = Acceptance.same(pairs(3, a: 40, b: 48, cv: 0.01, seed: 5), metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(s.verdict, "regressed", "\(s.reasons)"); XCTAssertEqual(s.regression, true)
    let c = s.costs![0]
    XCTAssertEqual(c.call, "worse"); XCTAssertGreaterThan(c.low!, c.margin)
    XCTAssertEqual(c.change / c.champion * 100, 20, accuracy: 3); XCTAssertTrue(c.text.hasPrefix("+"), c.text); XCTAssertTrue(c.text.contains("margin 5 %"), c.text)
    XCTAssertTrue(s.reasons[0].hasPrefix("\(cpu) is worse beyond its margin: +"), "\(s.reasons)")
  }

  func testANoisyRunCantTellAndSaysAddPairs() {
    // ±57 % noise (palette's band): the interval is far wider than the margin; never "no regression" by being noisy.
    let s = Acceptance.same(pairs(3, a: 100, b: 100, cv: 0.3, seed: 11), metric: "latencyMs", guards: [], lastLook: false)
    XCTAssertEqual(s.verdict, "inconclusive", "\(s.reasons)")
    XCTAssertGreaterThan(s.band!, 15, "a wide band…")
    XCTAssertTrue(s.reasons.contains { $0.hasPrefix("can't tell on latencyMs") }); XCTAssertEqual(s.reasons.last, "add pairs: the interval narrows with them")
    let last = Acceptance.same(pairs(3, a: 100, b: 100, cv: 0.3, seed: 11), metric: "latencyMs", guards: [], lastLook: true)
    XCTAssertTrue(last.reasons.contains { $0.hasPrefix("still inconclusive at 3 + 3") })
  }

  func testAGuardFailureIsARegressionAndASnapshotIsALook() {
    let g = Acceptance.same(pairs(3, a: 40, b: 30, cv: 0.01, seed: 7, checksB: ["landed"]), metric: cpu, guards: ["checks"], lastLook: false)
    XCTAssertEqual(g.verdict, "regressed"); XCTAssertNil(g.regression == true ? 1 : nil, "a broken guard isn't a slowdown")
    XCTAssertTrue(g.reasons[0].hasPrefix("landed failed on the candidate"), "\(g.reasons)")
    // A feature changes what it shows: a snapshot over tolerance is a look, not a verdict.
    var p = pairs(3, a: 40, b: 40, cv: 0.005, seed: 7)
    for i in p.indices { p[i].b.guards = [GuardResult(name: "snapshot-diff", pass: false, detail: "4.5 % of the pixels differ", review: true)] }
    let r = Acceptance.same(p, metric: cpu, guards: ["checks", "snapshot-diff"], lastLook: false)
    XCTAssertEqual(r.verdict, "noRegression", "\(r.reasons)")
    XCTAssertTrue(r.reasons.contains { $0.hasPrefix("look: ") }, "\(r.reasons)")
  }

  func testAFrameGuardWorseBeyondItsMarginRegresses() {
    let s = Acceptance.same(pairs(3, a: 40, b: 40, cv: 0.005, seed: 3, hitchA: 3, hitchB: 40), metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(s.verdict, "regressed", "\(s.reasons)")
    XCTAssertEqual(s.costs?.first { $0.metric == "hitchTimeRatioMsPerS" }?.call, "worse")
    // An adapter that reports no frame metrics per side: the objective decides, and the stage says what it couldn't check.
    var p = pairs(3, a: 40, b: 40, cv: 0.005, seed: 3)
    for i in p.indices { p[i].a.hitchTimeRatioMsPerS = nil; p[i].b.hitchTimeRatioMsPerS = nil; p[i].a.longestStretchMs = nil; p[i].b.longestStretchMs = nil }
    let n = Acceptance.same(p, metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(n.verdict, "noRegression"); XCTAssertEqual(n.costs?.count, 1)
    XCTAssertTrue(n.reasons.contains("not checked: hitchTimeRatioMsPerS, longestStretchMs (the adapter reports none per side)"), "\(n.reasons)")
  }

  func testUntrustedRepsNeverDecideASameCheck() {
    var p = pairs(3, a: 40, b: 40, cv: 0.005, seed: 1); p[1].b.quiet = false
    let s = Acceptance.same(p, metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(s.verdict, "untrusted"); XCTAssertNil(s.costs)
    // …except a guard the candidate failed on a trusted pair.
    var g = pairs(3, a: 40, b: 40, cv: 0.005, seed: 1, checksB: ["landed"]); g[1].b.quiet = false
    XCTAssertEqual(Acceptance.same(g, metric: cpu, guards: ["checks"], lastLook: false).verdict, "regressed")
  }

  // MARK: the inconclusive screen (b3)

  func testABorderlineScreenIsInconclusiveNotRejected() {
    // palette: won 2/3, gain 10.6 %, band ±57 %; needsreel: one pair +21.8 %, two −6 / −16 %.
    let palette = Acceptance.screen(pairs(a: [100, 100, 100], b: [89.4, 160, 60]), metric: "latencyMs", guards: [])
    XCTAssertEqual(palette.verdict, "inconclusive", "\(palette.reasons)")
    XCTAssertTrue(palette.reasons.last!.hasPrefix("can't tell: the gain could be anywhere in"), "\(palette.reasons)")
    let needsreel = Acceptance.screen(pairs(a: [10, 10, 10], b: [7.82, 10.6, 11.6]), metric: cpu, guards: [])
    XCTAssertEqual(needsreel.verdict, "inconclusive", "\(needsreel.reasons)")
    // Rejected stays for slower in every pair, a guard, and a gain that can't reach 5 % even at best.
    XCTAssertEqual(Acceptance.screen(pairs(a: [10, 10, 10], b: [10.5, 11, 12]), metric: cpu, guards: []).verdict, "rejected")
    let small = Acceptance.screen(pairs(a: [100, 100, 100], b: [98, 98.2, 97.9]), metric: cpu, guards: [])
    XCTAssertEqual(small.verdict, "rejected"); XCTAssertTrue(small.reasons.last!.hasPrefix("even at best the gain is"), "\(small.reasons)")
    XCTAssertEqual(Acceptance.screen(pairs(3, a: 62, b: 12.4, seed: 7, checksB: ["landed"]), metric: cpu, guards: ["checks"]).verdict, "rejected")
  }

  func testAQuietSameBuildScreenIsStillRejected() {
    var rejected = 0
    for seed in UInt64(1)...200 where Acceptance.screen(pairs(3, a: 41.2, b: 41.2, cv: 0.01, seed: seed), metric: cpu, guards: []).verdict == "rejected" { rejected += 1 }
    XCTAssertGreaterThanOrEqual(rejected, 190, "on a quiet Mac a same build's screen still filters")
  }

  func testAScreenWithMorePairsNeedsAsManyWinsAsItsSize() {
    // 6 pairs, 5 won by ≥ 10 %: promising (6 needs 5); 4 won: not.
    let five = Acceptance.screen(pairs(a: [40, 40, 40, 40, 40, 40], b: [36, 44, 30, 34, 33, 35]), metric: cpu, guards: [])
    XCTAssertEqual(five.verdict, "promising", "\(five.reasons)")
    let four = Acceptance.screen(pairs(a: [40, 40, 40, 40, 40, 40], b: [36, 44, 30, 34, 45, 35]), metric: cpu, guards: [])
    XCTAssertNotEqual(four.verdict, "promising")
    XCTAssertTrue(four.reasons[0].hasPrefix("the candidate won 4 of 6 pairs (a screen of 6 needs 5)"), "\(four.reasons)")
  }

  // MARK: the stopping rules

  func testExpectSameChecksStayOutOfTheStoppingRules() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ m: Double) -> String { Clock.iso(t0.addingTimeInterval(m * 60)) }
    var l: [LedgerEntry] = [LedgerEntry(experiment: "-", state: "session", at: at(0))]
    for i in 1...6 { var e = LedgerEntry(experiment: String(format: "%04d", i), state: "inconclusive", at: at(Double(i))); e.expect = "same"; l.append(e) }
    for i in 7...12 { var e = LedgerEntry(experiment: String(format: "%04d", i), state: "regressed", at: at(Double(i))); e.expect = "same"; l.append(e) }
    XCTAssertTrue(Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(4 * 3600))).isEmpty, "feature checks: no streak, no time budget")
    // An inconclusive optimisation screen neither extends nor breaks a streak.
    for i in 13...16 {
      l.append(LedgerEntry(experiment: String(format: "%04d", i), state: "built", at: at(Double(i))))
      l.append(LedgerEntry(experiment: String(format: "%04d", i), state: "rejected", at: at(Double(i))))
    }
    l.append(LedgerEntry(experiment: "0017", state: "inconclusive", at: at(17)))
    l.append(LedgerEntry(experiment: "0018", state: "rejected", at: at(18)))
    let r = Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(1800)))
    XCTAssertEqual(r, ["5 non-promising candidates in a row"])
    // The clock started at the first optimisation experiment (13 min), not the session (0).
    XCTAssertFalse(Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(7300))).contains { $0.contains("time budget") })
    XCTAssertTrue(Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(13 * 60 + 7200))).contains { $0.contains("time budget") })
  }

  func testTheTimeBudgetRunsFromTheFirstOptimisationAndNotWhileFeatureChecksRun() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ m: Double) -> String { Clock.iso(t0.addingTimeInterval(m * 60)) }
    func line(_ id: String, _ state: String, _ m: Double, same: Bool = false) -> LedgerEntry { var e = LedgerEntry(experiment: id, state: state, at: at(m)); if same { e.expect = "same" }; return e }
    func budget(_ l: [LedgerEntry], _ m: Double) -> String? { Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(m * 60))).first { $0.contains("time budget") } }
    // An owner's champion, a run and a baseline, then a feature check: no optimisation yet, no clock.
    var l = [line("-", "session", 0), line("0000", "promoted", 1), line("m0001", "measure", 2), line("m0002", "baseline", 3),
             line("0001", "built", 30, same: true), line("0001", "noRegression", 40, same: true)]
    XCTAssertNil(Stopping.budgetClock(l, now: t0.addingTimeInterval(600 * 60)))
    XCTAssertNil(budget(l, 600))
    // The first optimisation experiment starts it: its feature check before it costs nothing.
    l.append(line("0002", "built", 60)); l.append(line("0002", "rejected", 62))
    XCTAssertEqual(Stopping.budgetClock(l, now: t0.addingTimeInterval(70 * 60))?.spentS, 600)
    XCTAssertNil(budget(l, 179)); XCTAssertNotNil(budget(l, 180))
    // A feature check's screen (built → verdict) and full (full → verdict) after it aren't counted; the gap before the
    // full (its `full` line) and a check's verdict after another experiment's line are.
    l += [line("0003", "built", 70, same: true), line("0003", "inconclusive", 75, same: true),
          line("0003", "full", 80, same: true), line("0003", "noRegression", 100, same: true),
          line("0004", "built", 110, same: true), line("0005", "built", 112), line("0004", "regressed", 118, same: true)]
    let c = Stopping.budgetClock(l, now: t0.addingTimeInterval(200 * 60))
    XCTAssertEqual(c?.featureS, 25 * 60, "5 min of screen + 20 min of full")
    XCTAssertEqual(c?.spentS, (140 - 25) * 60)
    XCTAssertNil(budget(l, 204)); XCTAssertEqual(budget(l, 205), "the session's time budget (120 min) is spent: 120 min since its first optimisation experiment, not counting 25 min of expect-same stages")
    // A check screened later (`--no-screen`, then `exp screen`) with other lines between: its stage can't be told from
    // the gap, so it counts.
    let later = [line("-", "session", 0), line("0001", "built", 10, same: true), line("0002", "built", 20), line("0002", "rejected", 21), line("0001", "inconclusive", 30, same: true)]
    XCTAssertEqual(Stopping.budgetClock(later, now: t0.addingTimeInterval(40 * 60))?.featureS, 0)
  }
}

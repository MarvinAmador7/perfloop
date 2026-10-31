import XCTest
@testable import PerfLoopKit

/// SPEC §5.1 on synthetic samples: noise is never a regression, a clear win is a win, guards veto, "unknown"
/// extends and ends as "no decision".
final class AcceptanceTests: XCTestCase {
  let cpu = "mainThreadCpuMsPerStep"

  func testSameBuildIsNeverARegressionNorAWin() {
    var promising = 0
    for seed in UInt64(1)...200 {
      let s = Acceptance.screen(pairs(3, a: 41.2, b: 41.2, seed: seed), metric: cpu, guards: ["checks"])
      if s.verdict == "promising" { promising += 1 }                  // a filter lets a few through; the full stops them
      XCTAssertNil(s.regression, "seed \(seed)")
      let f = Acceptance.full(pairs(10, a: 41.2, b: 41.2, seed: seed), metric: cpu, guards: ["checks"], lastLook: true)
      XCTAssertNotEqual(f.regression, true, "seed \(seed): \(f.reasons)")
      XCTAssertNotEqual(f.verdict, "won", "seed \(seed): \(f.reasons)")
    }
    XCTAssertLessThanOrEqual(promising, 6, "a same-build screen passes ≤ 3 % of the time at 3 % noise")
  }

  func testAFiveTimesWinIsPromisingAndWins() {
    let s = Acceptance.screen(pairs(3, a: 62, b: 12.4, seed: 7), metric: cpu, guards: ["checks"])
    XCTAssertEqual(s.verdict, "promising", "\(s.reasons)")
    XCTAssertEqual(s.wins, 3)
    XCTAssertGreaterThan(s.medianGainPct!, 75)
    XCTAssertEqual(s.signP, 0.125)                                     // three pairs can't be significant
    let f = Acceptance.full(pairs(5, a: 62, b: 12.4, seed: 8), metric: cpu, guards: ["checks"], lastLook: false)
    XCTAssertEqual(f.verdict, "won", "\(f.reasons)")
    XCTAssertEqual(f.mwuP!, 2.0 / 252, accuracy: 1e-5)                 // 5 v 5, fully separated
    XCTAssertEqual(f.regression, false)
    XCTAssertEqual(f.frameGuards?["hitchTimeRatioMsPerS"]?.pass, true)
  }

  func testAFiveTimesLossIsARegression() {
    let f = Acceptance.full(pairs(5, a: 12.4, b: 62, seed: 9), metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(f.verdict, "lost"); XCTAssertEqual(f.regression, true)
    let s = Acceptance.screen(pairs(3, a: 12.4, b: 62, seed: 9), metric: cpu, guards: [])
    XCTAssertEqual(s.verdict, "rejected"); XCTAssertTrue(s.reasons.contains { $0.contains("slower in every pair") })
  }

  func testCorrectnessGuardsVetoAWin() {
    // A blank column is fast (SPEC §5.5): the objective wins, `landed` fails on the candidate only.
    let s = Acceptance.screen(pairs(3, a: 62, b: 12.4, seed: 7, checksB: ["landed"]), metric: cpu, guards: ["checks"])
    XCTAssertEqual(s.verdict, "rejected"); XCTAssertFalse(s.guardsPassed)
    XCTAssertTrue(s.reasons.contains { $0.contains("landed failed on the candidate") })
    let f = Acceptance.full(pairs(5, a: 62, b: 12.4, seed: 8, checksB: ["landed"]), metric: cpu, guards: ["landed"], lastLook: false)
    XCTAssertEqual(f.verdict, "lost")
    // A check the manifest doesn't name as a guard, and that the scenario doesn't gate on, doesn't veto.
    XCTAssertEqual(Acceptance.screen(pairs(3, a: 62, b: 12.4, seed: 7, checksB: ["typing"]), metric: cpu, guards: ["landed"]).verdict, "promising")
  }

  func testFrameGuardVetoesAnObjectiveWin() {
    let f = Acceptance.full(pairs(5, a: 62, b: 12.4, seed: 8, hitchA: 3, hitchB: 40), metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(f.verdict, "lost"); XCTAssertEqual(f.frameGuards?["hitchTimeRatioMsPerS"]?.pass, false)
  }

  func testUnknownExtendsThenEndsAsNoDecision() {
    let p = pairs(a: [10, 11, 12, 13, 14], b: [7, 8, 9, 11.5, 12.5])   // exact p = 0.1508, effect 25 %
    let f = Acceptance.full(p, metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(f.verdict, "unknown", "\(f.reasons)"); XCTAssertEqual(f.mwuP!, 0.150794, accuracy: 1e-5)
    XCTAssertEqual(Acceptance.full(p, metric: cpu, guards: [], lastLook: true).verdict, "noDecision")
  }

  func testSmallButSignificantGainIsNotAWin() {
    // 2 % better, every time: significant, under the 5 % floor.
    let f = Acceptance.full(pairs(a: [100, 100.2, 100.4, 100.6, 100.8], b: [98, 98.2, 98.4, 98.6, 98.8]), metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(f.verdict, "lost"); XCTAssertTrue(f.reasons.contains { $0.contains("under max(band") })
  }

  func testUnusablePairsDontDecide() {
    var p = pairs(3, a: 62, b: 12.4, seed: 7)
    p[1].b.profiled = true
    p[2].failure = "exit 2"
    let s = Acceptance.screen(p, metric: cpu, guards: [])
    XCTAssertEqual(s.verdict, "rejected"); XCTAssertEqual(s.objective["a"]?.count, 1)
    XCTAssertTrue(Acceptance.unusable(p[1])!.contains("profiler"))
  }

  func testSecondFixtureNotWorse() {
    XCTAssertTrue(Acceptance.notWorse(pairs(3, a: 80, b: 80, seed: 3), metric: cpu, guards: []).1)
    XCTAssertFalse(Acceptance.notWorse(pairs(3, a: 80, b: 120, seed: 3), metric: cpu, guards: []).1)
  }

  func testStoppingRules() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var l: [LedgerEntry] = [LedgerEntry(experiment: "-", state: "session", at: Clock.iso(t0))]
    for i in 1...5 { l.append(LedgerEntry(experiment: String(format: "%04d", i), state: "rejected", at: Clock.iso(t0.addingTimeInterval(Double(i) * 60)))) }
    XCTAssertTrue(Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(600))).contains { $0.contains("5 non-promising") })
    l.append(LedgerEntry(experiment: "0006", state: "promising"))
    XCTAssertTrue(Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(600))).isEmpty)
    XCTAssertTrue(Stopping.reasons(StopInput(session: l, now: t0.addingTimeInterval(7300))).contains { $0.contains("time budget") })
    XCTAssertFalse(Stopping.reasons(StopInput(session: l, now: t0, budgetPassed: true, largestAttributablePct: 3)).count < 2)
  }
}

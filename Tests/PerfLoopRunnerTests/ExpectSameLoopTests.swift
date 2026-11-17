import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// Feature verification against the fake adapter, whose `ab` is deskbench's (the adapter owns the pair, as capcomd's
/// CapcomdDeskBench does): `exp new --expect same` ends no regression, regressed or inconclusive, gets no "drop it",
/// stays out of the stopping rules and never moves the champion; a screen that can't tell takes more pairs or the full
/// without an owner flag.
final class ExpectSameLoopTests: FakeBenchCase {
  func explain(_ id: String) throws -> String { try String(contentsOfFile: store.abs("exp/\(id)/explain.txt"), encoding: .utf8) }

  func same(_ name: String, _ values: [String: String]) throws -> Experiment {
    var o = Loop.NewOptions(hypothesis: "the sidebar toggle"); o.expect = "same"
    o.bench = try bench(name, values)
    return try loop.new(o)
  }

  func testAFeatureThatCostsNothingSaysSoAndIsNeverPromoted() throws {
    try baseline(["NOISE": "0.005"])
    // The adapter's own comparison of each pair says "regression" and exits 4: the runner reads the numbers, not that.
    let e = try same("feature", ["NOISE": "0.005", "AB_EXIT": "4", "AB_REGRESSION": "true"])
    XCTAssertEqual(e.expect, "same")
    XCTAssertEqual(e.state, .noRegression, "\(e.screen!.reasons)")
    XCTAssertEqual(e.screen?.costs?.map(\.metric), ["mainThreadCpuMsPerStep", "hitchTimeRatioMsPerS", "longestStretchMs"])
    XCTAssertTrue(e.state.terminal)
    let text = try explain(e.id)
    XCTAssertTrue(text.hasPrefix("exp 0001 · noRegression · code · expect same · step on crew17\n"), text)
    XCTAssertTrue(text.contains("screen: NO REGRESSION on mainThreadCpuMsPerStep, 3 pair(s) (orders AB BA AB), change "), text)
    XCTAssertTrue(text.contains("  frame guard hitchTimeRatioMsPerS: 3 → 3, change 0 (90 % interval 0 … 0, margin 2): pass"), text)
    XCTAssertTrue(text.contains("next: it costs nothing measurable: say so in the feature's PR"), text)
    XCTAssertFalse(text.contains("drop it")); XCTAssertFalse(text.contains("stop:")); XCTAssertFalse(text.contains("suggest ("))
    XCTAssertTrue(store.ledger.entries().filter { $0.experiment == e.id }.allSatisfy { $0.expect == "same" })
    XCTAssertTrue(store.ledger.entries().last!.text.contains("· expect same"))
    XCTAssertThrowsError(try loop.promote(e.id)) { XCTAssertTrue("\($0)".contains("never moves the champion"), "\($0)") }
    XCTAssertEqual(try loop.full(e.id).state, .noRegression, "decided: nothing to add")
    XCTAssertThrowsError(try loop.screen(e.id, more: 3)) { XCTAssertEqual(($0 as? PLError)?.code, 6) }
    XCTAssertEqual(store.champion()?.experiment, "0000")
  }

  func testARegressionSaysByHowMuchAndWhereToLook() throws {
    try baseline(["NOISE": "0.005"])
    let e = try same("slow", ["NOISE": "0.005", "CPU": "48"])
    XCTAssertEqual(e.state, .regressed, "\(e.screen!.reasons)")
    let text = try explain(e.id)
    XCTAssertTrue(text.contains("screen: REGRESSED on mainThreadCpuMsPerStep"), text)
    XCTAssertTrue(text.contains("next: regressed on mainThreadCpuMsPerStep by +"), text)
    XCTAssertEqual(e.screen!.costs![0].change / e.screen!.costs![0].champion * 100, 20, accuracy: 2)
    XCTAssertTrue(text.contains("perfloop profile exp/0001 and perfloop diff champion exp/0001"), text)
    XCTAssertTrue(text.contains("--expect same"), text)
    XCTAssertFalse(text.contains("drop it"), text)
  }

  func testAGuardFailedLaterTurnsNoRegressionIntoRegressed() throws {
    try baseline(["NOISE": "0.005"])
    var o = Loop.NewOptions(hypothesis: "h"); o.expect = "same"; o.screen = false
    o.bench = try bench("broken", ["NOISE": "0.005", "CHECK_FAIL": "landed"])
    var e = try loop.new(o)
    e.state = .noRegression; try store.save(e)
    let (g, run) = try loop.guards(e.id)
    XCTAssertFalse(run.pass); XCTAssertEqual(g.state, .regressed)
    let text = try explain(e.id)
    XCTAssertTrue(text.contains("next: the feature broke what a guard checks"), text)
  }

  func testCantTellAddsPairsThenTheFullDecidesOrSaysSo() throws {
    // Every other pair 25 % slower, then 25 % faster: an interval around 0 far wider than the 5 % margin, every look.
    try baseline(["NOISE": "0"])
    var e = try same("noisy", ["NOISE": "0", "SEQ": "30,50"])
    XCTAssertEqual(e.state, .inconclusive, "\(e.screen!.reasons)")
    var text = try explain(e.id)
    XCTAssertTrue(text.contains("next: can't tell yet (mainThreadCpuMsPerStep "), text)
    XCTAssertTrue(text.contains("perfloop exp screen 0001 --more 3, or perfloop exp full 0001"), text)
    XCTAssertFalse(text.contains("drop it"), text)
    e = try loop.screen(e.id, more: 3)
    XCTAssertEqual(adapterCalls("ab").count, 6, "3 more pairs, the first 3 kept")
    XCTAssertEqual(e.screen?.pairs.count, 6); XCTAssertEqual(e.screen?.extendedTo, 6)
    XCTAssertEqual(e.state, .inconclusive)
    e = try loop.full(e.id)
    XCTAssertNil(e.ownerFlags); XCTAssertNil(e.forced)
    XCTAssertEqual(e.state, .inconclusive, "\(e.full!.reasons)")
    XCTAssertEqual(e.full?.extendedTo, 10); XCTAssertEqual(adapterCalls("ab").count, 16)
    XCTAssertTrue(e.full!.reasons.contains("still inconclusive at 10 + 10: this runner can't resolve a change that small"), "\(e.full!.reasons)")
    text = try explain(e.id)
    XCTAssertTrue(text.contains("next: can't tell at 10 + 10 on this runner"), text)
    XCTAssertEqual(try loop.full(e.id).state, .inconclusive)
    XCTAssertEqual(adapterCalls("ab").count, 16, "a full at its last look isn't run again")
    XCTAssertTrue(Stopping.reasons(StopInput(session: store.ledger.currentSession(), now: Date().addingTimeInterval(5 * 3600))).isEmpty)
  }

  func testUntrustedRepsNeverDecideAFeatureCheck() throws {
    try baseline(["NOISE": "0.005"])
    setenv("FAKE_ENV_QUIET", "false", 1); defer { unsetenv("FAKE_ENV_QUIET") }
    let e = try same("feature", ["NOISE": "0.005"])
    XCTAssertEqual(e.state, .built); XCTAssertEqual(e.screen?.verdict, "untrusted")
    XCTAssertTrue(try explain(e.id).contains("next: perfloop exp screen 0001 once the Mac is quiet"))
    unsetenv("FAKE_ENV_QUIET")
    XCTAssertEqual(try loop.screen(e.id).state, .noRegression)
  }

  func testRefusesAnUnknownExpectation() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "h"); o.expect = "slower"; o.bench = try bench("x", [:])
    XCTAssertThrowsError(try loop.new(o)) { XCTAssertTrue("\($0)".contains("--expect faster|same"), "\($0)") }
  }

  // MARK: the inconclusive screen of an optimisation (b3)

  func testAnInconclusiveScreenTakesMorePairsAndAFullWithoutAnOwnerFlag() throws {
    try baseline(["NOISE": "0"])
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["NOISE": "0", "SEQ": "36,44,30,34,33,35"])
    var e = try loop.new(o)
    XCTAssertEqual(e.state, .inconclusive, "\(e.screen!.reasons)")              // +10 %, −10 %, +25 %
    var text = try explain(e.id)
    XCTAssertTrue(text.contains("screen: INCONCLUSIVE on mainThreadCpuMsPerStep, 3 pair(s)"), text)
    XCTAssertTrue(text.contains("next: the screen can't tell, so don't drop it on this: perfloop exp screen 0001 --more 3 (promising then needs 5 of 6 pairs won), or straight to perfloop exp full 0001"), text)
    XCTAssertFalse(store.ledger.entries().contains { $0.state == "rejected" })
    e = try loop.screen(e.id, more: 3)
    XCTAssertEqual(e.state, .promising, "\(e.screen!.reasons)")                // 5 of 6 won
    XCTAssertEqual(adapterCalls("ab").count, 6)
    XCTAssertThrowsError(try loop.screen(e.id, more: 3)) { XCTAssertTrue("\($0)".contains("perfloop exp full 0001"), "\($0)") }

    // Another that can't tell goes straight to the full: no owner flag, nothing forced.
    var o2 = Loop.NewOptions(hypothesis: "h2"); o2.bench = try bench("cand2", ["NOISE": "0", "SEQ": "36,44,30"]); o2.screen = false
    var e2 = try loop.new(o2)
    XCTAssertThrowsError(try loop.screen(e2.id, more: 3)) { XCTAssertEqual(($0 as? PLError)?.code, 1, "not screened yet") }
    e2 = try loop.screen(e2.id)
    XCTAssertEqual(e2.state, .inconclusive)
    e2 = try loop.full(e2.id)
    XCTAssertNotNil(e2.full); XCTAssertNil(e2.forced); XCTAssertNil(e2.ownerFlags)
    text = try explain(e2.id)
    XCTAssertFalse(text.contains("FORCED"), text)
  }

  func testMoreIsCappedAndRefusedOnADecidedScreen() throws {
    try baseline(["NOISE": "0"])
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["NOISE": "0", "SEQ": "36,44,30,50,30,50,30,50,30,50"])
    var e = try loop.new(o)
    XCTAssertEqual(e.state, .inconclusive)
    e = try loop.screen(e.id, more: 50)
    XCTAssertEqual(e.screen?.pairs.count, Acceptance.maxScreenPairs)
    XCTAssertEqual(e.state, .inconclusive, "\(e.screen!.reasons)")
    XCTAssertTrue(try explain(e.id).contains("next: the screen can't tell at 10 pairs: perfloop exp full 0001"))
    XCTAssertThrowsError(try loop.screen(e.id, more: 1)) { XCTAssertTrue("\($0)".contains("the most a screen takes"), "\($0)") }
    var r = Loop.NewOptions(hypothesis: "slower"); r.bench = try bench("slow", ["NOISE": "0", "CPU": "50"])
    let rejected = try loop.new(r)
    XCTAssertEqual(rejected.state, .rejected)
    XCTAssertThrowsError(try loop.screen(rejected.id, more: 3)) { XCTAssertEqual(($0 as? PLError)?.code, 6) }
  }
}

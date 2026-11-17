import XCTest
@testable import PerfLoopKit

/// Untrusted reps never decide (ADAPTER.md §3, Trust): what an adapter says about a rep's window, exit and machine
/// reaches its side, a stage that needs an untrusted pair says UNTRUSTED with the count and the cause, the messages name
/// the side and the field, and a failure a rerun can't fix says so.
final class TrustTests: XCTestCase {
  let cpu = "mainThreadCpuMsPerStep"

  func json(_ s: String) throws -> JSONValue { try PLJSON.decode(JSONValue.self, from: Data(s.utf8)) }

  /// `n` promising pairs whose sides are busy.
  func busy(_ n: Int, seed: UInt64 = 7) -> [Pair] {
    pairs(n, a: 62, b: 12.4, seed: seed).map { p in
      var p = p
      p.a.quiet = false; p.a.busyPct = 99.8; p.a.busy = ["swift-build", "swift-frontend"]
      p.b.quiet = false; p.b.busyPct = 97.1; p.b.busy = ["swift-build"]
      return p
    }
  }

  /// `n` pairs, the candidate's window not key while the champion's is right.
  func notKey(_ n: Int, orders: [String]) -> [Pair] {
    pairs(n, a: 62, b: 12.4, seed: 7).enumerated().map { i, p in
      var p = p
      p.order = orders[i % orders.count]
      p.a.trustworthy = true
      p.b.trustworthy = false; p.b.windowFailed = ["keyWindow"]; p.b.exit = 5
      return p
    }
  }

  // MARK: readings

  func testAbRunsCarryEachSidesExitAndMachine() throws {
    // deskbench's ab: summaries plus runs[] (one process per side here, as the runner calls it).
    let v = try json("""
    { "schema": "deskbench.ab/1", "summaryA": { "reps": 1, "mainThreadCpuMsPerStep": { "median": 41 } }, "summaryB": { "reps": 1, "mainThreadCpuMsPerStep": { "median": 38 } },
      "runs": [ { "pair": 0, "side": "A", "position": 1, "busyPct": 99.8, "builds": ["swift-build", "swift-frontend"], "waitedS": 10, "quiet": false, "exit": 5 },
                { "pair": 0, "side": "B", "position": 2, "busyPct": 12, "builds": [], "waitedS": 0.5, "quiet": true, "exit": 0,
                  "window": { "appActive": true, "keyWindow": false, "visible": true, "occluded": false } } ] }
    """)
    let a = try XCTUnwrap(Readings.sides(ab: v, label: "A", metric: cpu).first), b = try XCTUnwrap(Readings.sides(ab: v, label: "B", metric: cpu).first)
    XCTAssertEqual(a.objective, 41); XCTAssertEqual(a.exit, 5); XCTAssertEqual(a.quiet, false); XCTAssertEqual(a.busyPct, 99.8); XCTAssertEqual(a.busy, ["swift-build", "swift-frontend"])
    XCTAssertNil(a.trustworthy)
    XCTAssertEqual(b.exit, 0); XCTAssertEqual(b.quiet, true); XCTAssertNil(b.busy); XCTAssertEqual(b.trustworthy, false); XCTAssertEqual(b.windowFailed, ["keyWindow"])
    XCTAssertEqual(Acceptance.distrust(a), ["not quiet (busy 99.8 %: swift-build, swift-frontend)"])
    XCTAssertEqual(Acceptance.distrust(b), ["window keyWindow=false"])

    // An older ab, summaries only: nothing to judge trust on, so nothing is set.
    let old = try json(#"{ "summaryA": { "reps": 1, "mainThreadCpuMsPerStep": { "median": 41 } } }"#)
    let o = try XCTUnwrap(Readings.sides(ab: old, label: "A", metric: cpu).first)
    XCTAssertNil(o.exit); XCTAssertNil(o.quiet); XCTAssertNil(o.trustworthy); XCTAssertEqual(Acceptance.distrust(o), [])
  }

  func testAbRepsLineUpWithTheirRuns() throws {
    let v = try json("""
    { "repsA": [ { "cpuMsPerStep": 40, "window": { "appActive": false, "keyWindow": false, "visible": true, "occluded": true } }, { "cpuMsPerStep": 41 } ],
      "runs": [ { "side": "A", "exit": 5, "quiet": true }, { "side": "A", "exit": 0, "quiet": false, "busyPct": 80 } ] }
    """)
    let s = Readings.sides(ab: v, label: "A", metric: cpu)
    XCTAssertEqual(s.map(\.exit), [5, 0]); XCTAssertEqual(s.map(\.quiet), [true, false])
    XCTAssertEqual(s[0].windowFailed, ["appActive", "keyWindow", "occluded"])
    XCTAssertEqual(Acceptance.distrust(s[0]), ["window appActive=false, keyWindow=false, occluded=true"])
  }

  func testARunResultSaysOnceForEveryRep() throws {
    // deskbench.result/1 keeps the window and the noise at the top, not per rep.
    let v = try json("""
    { "schema": "deskbench.result/1", "exitCode": 5, "window": { "appActive": true, "keyWindow": true, "visible": true, "occluded": false },
      "noise": { "quiet": false, "reasons": ["8 of 65 idle frames were late before the scenario started"] },
      "reps": [ { "cpuMsPerStep": 40, "steps": [ {} ] } ] }
    """)
    let s = try XCTUnwrap(Readings.sides(run: v, metric: cpu).first)
    XCTAssertEqual(s.trustworthy, true); XCTAssertEqual(s.quiet, false); XCTAssertEqual(s.exit, 5)
    XCTAssertEqual(s.busy, ["8 of 65 idle frames were late before the scenario started"])
    // A rep's own state wins over the top level's.
    let w = try json(#"{ "quiet": true, "reps": [ { "cpuMsPerStep": 40, "quiet": false, "busyPct": 70, "busy": ["xcodebuild"] } ] }"#)
    let r = try XCTUnwrap(Readings.sides(run: w, metric: cpu).first)
    XCTAssertEqual(r.quiet, false); XCTAssertEqual(r.busy, ["xcodebuild"]); XCTAssertNil(r.exit)
  }

  // MARK: acceptance

  func testUntrustedPairsNeverDecideAScreen() {
    let s = Acceptance.screen(busy(3), metric: cpu, guards: [])
    XCTAssertEqual(s.verdict, "untrusted", "a five-times win on a busy Mac is not promising")
    XCTAssertEqual(s.untrusted, "6/6 reps untrusted: not quiet ×6 (busy up to 99.8 %: swift-build, swift-frontend)")
    XCTAssertEqual(s.reasons.first, s.untrusted)
    XCTAssertTrue(Acceptance.unusable(busy(1)[0])!.hasPrefix("untrusted on the champion: not quiet (busy 99.8 %"))
    // Nor a loss.
    var slow = pairs(3, a: 12.4, b: 62, seed: 9); slow[0].b.exit = 5; slow[1].a.exit = 5; slow[2].b.exit = 5
    let r = Acceptance.screen(slow, metric: cpu, guards: [])
    XCTAssertEqual(r.verdict, "untrusted"); XCTAssertEqual(r.untrusted, "3/6 reps untrusted: exit 5 (the bench's own untrusted) ×3")
    XCTAssertNil(r.regression)
  }

  func testTrustedPairsThatRejectStillReject() {
    // Pair 1 untrusted; pair 2, trusted, the candidate lost. A lost pair no longer rejects (b3: mixed signs can't tell),
    // and whether every pair was slower depends on pair 1: the screen waits for it.
    var p = pairs(3, a: 40, b: 30, seed: 3)
    p[0].b.quiet = false
    p[1].b.objective = 50
    let s = Acceptance.screen(p, metric: cpu, guards: [])
    XCTAssertEqual(s.verdict, "untrusted", "\(s.reasons)")
    XCTAssertEqual(s.untrusted, "1/6 reps untrusted: not quiet ×1")
    // A guard it failed on a trusted pair rejects it whatever the untrusted pair says; one on an untrusted pair alone doesn't.
    var g = pairs(3, a: 62, b: 12.4, seed: 7, checksB: ["landed"]); g[0].a.quiet = false
    XCTAssertEqual(Acceptance.screen(g, metric: cpu, guards: ["checks"]).verdict, "rejected")
    var h = pairs(3, a: 62, b: 12.4, seed: 7); h[0].a.quiet = false; h[0].b.checksFailed = ["landed"]
    XCTAssertEqual(Acceptance.screen(h, metric: cpu, guards: ["checks"]).verdict, "untrusted")
  }

  func testAFullWaitsForEveryPairOfItsLook() {
    var p = pairs(5, a: 62, b: 12.4, seed: 8)
    p[3].a.trustworthy = false; p[3].a.windowFailed = ["appActive"]
    let f = Acceptance.full(p, metric: cpu, guards: [], lastLook: false)
    XCTAssertEqual(f.verdict, "untrusted"); XCTAssertEqual(f.repsPerSide, 4)
    XCTAssertTrue(f.reasons.contains { $0.contains("a rerun on a quiet Mac measures only the untrusted pairs again") }, "\(f.reasons)")
    let (s2, ok) = Acceptance.notWorse(busy(3), metric: cpu, guards: [])
    XCTAssertEqual(s2.verdict, "untrusted"); XCTAssertFalse(ok)
    XCTAssertFalse(s2.reasons.contains { $0.contains("worse on this fixture") })
  }

  /// F11: the side and the field, and no "rerun" for what a rerun can't fix.
  func testAOneSidedWindowInBothOrdersIsDeterministic() {
    let p = notKey(3, orders: ["AB", "BA"])
    XCTAssertEqual(Acceptance.unusable(p[0]), "untrusted on the candidate: window keyWindow=false (the champion's rep was fine)")
    XCTAssertFalse(Acceptance.unusable(p[0])!.contains("rerun"))
    let s = Acceptance.screen(p, metric: cpu, guards: [])
    XCTAssertEqual(s.verdict, "untrusted")
    XCTAssertEqual(s.untrusted, "3/6 reps untrusted: the candidate's window keyWindow=false ×3")
    XCTAssertTrue(s.reasons.contains { $0.hasPrefix("deterministic: the candidate's window keyWindow=false in all 3 untrusted pairs") }, "\(s.reasons)")
    XCTAssertFalse(s.reasons.joined().contains("rerun on"))
    // One order only: it could be whichever ran second, so not (yet) deterministic.
    XCTAssertNil(Acceptance.deterministic(notKey(3, orders: ["AB"])))
    // Both sides wrong is the machine (a locked screen, someone else in front): a rerun can help.
    var both = notKey(2, orders: ["AB", "BA"]); for i in both.indices { both[i].a.trustworthy = false; both[i].a.windowFailed = ["appActive"] }
    XCTAssertNil(Acceptance.deterministic(both))
    XCTAssertEqual(Acceptance.unusable(both[0]), "untrusted on the champion: window appActive=false; on the candidate: window keyWindow=false")
    // The other side's window unknown: not proven to be the build's.
    var unknown = notKey(2, orders: ["AB", "BA"]); for i in unknown.indices { unknown[i].a.trustworthy = nil }
    XCTAssertNil(Acceptance.deterministic(unknown))
  }

  // MARK: explain

  func experiment(_ state: ExpState, screen: Stage? = nil, full: Stage? = nil) -> Experiment {
    var e = Experiment(id: "0004", hypothesis: "h", scenario: "step", fixture: "crew17", parent: nil, build: nil)
    e.state = state; e.screen = screen; e.full = full
    return e
  }

  func testExplainSaysUntrustedAndNeverDropIt() {
    let s = Acceptance.screen(busy(3), metric: cpu, guards: [])
    let t = Explain.experiment(experiment(.built, screen: s), champion: nil)
    XCTAssertTrue(t.contains("screen: UNTRUSTED (6/6 reps untrusted: not quiet ×6 (busy up to 99.8 %: swift-build, swift-frontend)) on mainThreadCpuMsPerStep, 0 pair(s)"), t)
    XCTAssertTrue(t.contains("next: perfloop exp screen 0004 once the Mac is quiet and unlocked"), t)
    XCTAssertFalse(t.contains("drop it"), t)
    XCTAssertFalse(t.contains("trust: not checked"), t)
    let f = Acceptance.full(busy(5), metric: cpu, guards: [], lastLook: false)
    XCTAssertTrue(Explain.experiment(experiment(.full, screen: Acceptance.screen(pairs(3, a: 62, b: 12.4, seed: 7), metric: cpu, guards: []), full: f), champion: nil)
      .contains("next: perfloop exp full 0004 once the Mac is quiet"))
    // Deterministic: what to do instead of a rerun.
    let d = Explain.experiment(experiment(.built, screen: Acceptance.screen(notKey(2, orders: ["AB", "BA"]), metric: cpu, guards: [])), champion: nil)
    XCTAssertTrue(d.contains("next: a rerun won't help: the candidate's bench window is wrong the same way every time. If the change moves the keyboard"), d)
    XCTAssertTrue(d.contains("perfloop exp abandon 0004"), d)
    // No trust information at all (an old ab): decided, and labelled.
    let o = Explain.experiment(experiment(.promising, screen: Acceptance.screen(pairs(3, a: 62, b: 12.4, seed: 7), metric: cpu, guards: [])), champion: nil)
    XCTAssertTrue(o.contains("screen: PROMISING")); XCTAssertTrue(o.contains("trust: not checked"), o)
  }
}

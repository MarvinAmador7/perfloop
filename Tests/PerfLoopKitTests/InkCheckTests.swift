import XCTest
@testable import PerfLoopKit

/// v3 and v9 in the pure half: checks and guards counted per trusted rep (flaky N/M is a failure in every verdict
/// path), the built-in ink guard judged whatever the manifest lists, and the warning when a step's worst stretch was
/// the bench's own code.
final class InkCheckTests: XCTestCase {
  let cpu = "mainThreadCpuMsPerStep"

  func side(_ v: Double, passed: [String] = [], failed: [String] = [], guards: [GuardResult]? = nil) -> Side {
    var s = Side(objective: v, hitch: 2, longest: 40, checksFailed: failed); s.checksPassed = passed; s.guards = guards
    return s
  }

  // MARK: v9, the count

  func testATallyIsPerTrustedRepAndAMissingCheckDoesNotPass() {
    let t = Acceptance.tally([side(1, passed: ["landed", "drawn"]), side(1, passed: ["landed"], failed: ["drawn"]), side(1, passed: ["drawn"])])
    XCTAssertEqual(t.map(\.text), ["landed flaky 2/3", "drawn flaky 2/3"], "a rep that didn't report landed didn't pass it")
    XCTAssertEqual(Acceptance.tally([side(1, failed: ["x"]), side(1, failed: ["x"])]).first?.status, "failed")
    XCTAssertEqual(Acceptance.tally([side(1, passed: ["x"])]).first?.text, "x ✓ 1/1")
    // An `ab` summary lists only the failed checks: an unlisted one passed there.
    var summary = Side(objective: 1, checksFailed: []); summary.checksPassed = nil
    XCTAssertEqual(Acceptance.tally([side(1, failed: ["x"]), summary]).first?.text, "x flaky 1/2")
    let ink = GuardResult(name: "ink", pass: true, detail: ""), blank = GuardResult(name: "ink", pass: false, detail: "blank")
    let snap = GuardResult(name: "snapshot-diff", pass: false, detail: "", review: true)
    XCTAssertEqual(Acceptance.tally([side(1, guards: [ink, snap]), side(1, guards: [blank, snap])]).map(\.text), ["ink flaky 1/2"], "a snapshot is a look, not counted")
  }

  func testAFlakyCheckIsAFailureOfARunAndItsTextSaysFlaky() {
    let reps = (0..<3).map { i in MeasureRep(index: i, result: nil, side: side(10, passed: i == 1 ? [] : ["drawn"], failed: i == 1 ? ["drawn"] : [])) }
    let s = Measure.summary(reps)
    XCTAssertEqual(s.checksFailed, ["drawn"]); XCTAssertEqual(s.checks?.first?.text, "drawn flaky 2/3")
    var m = ScenarioRun(id: "m0001", kind: "run", target: "champion", build: Build(hash: "sha256:00", commit: "abc", dirty: false, configuration: "release", stamp: true),
                        scenario: "toggle", fixture: "f", metric: cpu)
    m.reps = reps; m.summary = s
    let text = Measure.text(m)
    XCTAssertTrue(text.contains("FAILED: check drawn flaky 2/3 (flaky: it passed in some trusted reps, not all; a failure)"), text)
    // An untrusted rep's failure isn't counted, pass or fail.
    var u = reps; u[1].untrusted = "not quiet"
    XCTAssertEqual(Measure.summary(u).checks?.first?.text, "drawn ✓ 2/2")
    let ok = Measure.summary((0..<2).map { MeasureRep(index: $0, result: nil, side: side(10, passed: ["landed"])) })
    m.summary = ok; m.reps = (0..<2).map { MeasureRep(index: $0, result: nil, side: side(10, passed: ["landed"])) }
    XCTAssertTrue(Measure.text(m).contains("checks: all passed in every trusted rep: landed ✓ 2/2"), Measure.text(m))
  }

  func testInAnExperimentAFlakyCandidateCheckVetoesOnceWithItsCount() {
    var p = pairs(3, a: 62, b: 12.4, seed: 7)
    for i in p.indices { p[i].a.checksPassed = ["drawn"]; p[i].b.checksPassed = i == 1 ? [] : ["drawn"]; if i == 1 { p[i].b.checksFailed = ["drawn"] } }
    let s = Acceptance.screen(p, metric: cpu, guards: ["checks"])
    XCTAssertEqual(s.verdict, "rejected")
    XCTAssertEqual(s.guardFailures, ["drawn failed on the candidate in pair 2 (passed on the champion) · the candidate passed 2/3 (flaky: a failure)"])
    // The same in an expect-same stage: regressed.
    XCTAssertEqual(Acceptance.same(p, metric: cpu, guards: ["checks"], lastLook: false).verdict, "regressed")
    // A candidate that stops reporting a check the champion passed has failed it.
    var d = pairs(1, a: 62, b: 12.4, seed: 7); d[0].a.checksPassed = ["drawn"]; d[0].b.checksPassed = []
    XCTAssertEqual(Acceptance.guardFailures(d, guards: ["checks"]), ["drawn failed on the candidate in pair 1 (passed on the champion)"])
  }

  func testACheckFlakyOnBothSidesInTheSamePairsSaysSoAndDoesNotVeto() {
    var p = pairs(3, a: 62, b: 12.4, seed: 7)
    for i in p.indices {
      p[i].a.checksPassed = i == 0 ? [] : ["drawn"]; p[i].b.checksPassed = i == 0 ? [] : ["drawn"]
      if i == 0 { p[i].a.checksFailed = ["drawn"]; p[i].b.checksFailed = ["drawn"] }
    }
    let s = Acceptance.screen(p, metric: cpu, guards: ["checks"])
    XCTAssertEqual(s.verdict, "promising", "\(s.reasons)")
    XCTAssertTrue(s.reasons.contains { $0.hasPrefix("check drawn fails on the champion too (champion 2/3, candidate 2/3)") }, "\(s.reasons)")
  }

  func testOnlyTrustedPairsJudgeAGuard() {
    // A blank region in a pair whose candidate rep was untrusted (a locked screen draws nothing): it can't count.
    var p = pairs(5, a: 40, b: 40, cv: 0.005, seed: 9)
    let ink = GuardResult(name: "ink", pass: true, detail: "drawn"), blank = GuardResult(name: "ink", pass: false, detail: "rows after select#0: blank")
    for i in p.indices { p[i].a.guards = [ink]; p[i].b.guards = [i == 2 ? blank : ink] }
    XCTAssertEqual(Acceptance.same(p, metric: cpu, guards: ["checks"], lastLook: false).verdict, "regressed", "ink is built in: no manifest needs to list it")
    p[2].b.quiet = false
    let s = Acceptance.same(p, metric: cpu, guards: ["checks"], lastLook: false)
    XCTAssertEqual(s.verdict, "untrusted", "\(s.reasons)")
    XCTAssertTrue(s.guardFailures.isEmpty, "\(s.guardFailures)")
    XCTAssertEqual(GuardNames.adapterRun(["checks", "ink", "rows-drawn"]), ["rows-drawn"], "never asked of an adapter: it judges ink on its own")
  }

  func testInkRegionsRoundTripAndExplainSaysWhereToLook() throws {
    var g = GuardResult(name: "ink", pass: false, detail: "pane after open: blank", artifacts: ["exp/0003/screen/p1/b/ink/open-pane.png"], value: 0, limit: 0.005)
    g.inkRegions = [InkRegionResult(region: "pane", after: "open", pass: false, ink: 0, min: 0.005, rect: [200, 0, 700, 600], detail: "blank", picture: "exp/0003/screen/p1/b/ink/open-pane.png")]
    let back = try PLJSON.decode(GuardResult.self, from: Data(PLJSON.encode(g).utf8))
    XCTAssertEqual(back, g)
    XCTAssertEqual(GuardResult(json: .object(["name": .string("ink"), "pass": .bool(true)]))?.inkRegions, nil, "an older record decodes")
    var p = pairs(1, a: 40, b: 40, seed: 1); p[0].b.guards = [g]
    let lines = Explain.guardLines(Stage(metric: cpu, pairs: p, verdict: "rejected"))
    XCTAssertEqual(lines, ["  guards pair 1: ink ✗ 0 % ink", "    look at (ink failed): exp/0003/screen/p1/b/ink/open-pane.png"])
  }

  // MARK: F18, the bench measuring itself

  func testBenchRoles() {
    let m: Set<String> = ["DeskBench"]
    XCTAssertEqual(Symbols.benchRole("DeskBench.Drive.inkOpened() -> Swift.Double", benchModules: m), .bench)
    XCTAssertEqual(Symbols.benchRole("closure #1 () -> () in DeskBench.Drive.inkOpened() -> Swift.Double", benchModules: m), .bench)
    XCTAssertEqual(Symbols.benchRole("(1) suspend resume partial function for closure #2 @Swift.MainActor (PerfLoopHost.Run) async throws -> () in DeskBench", benchModules: m), .driver)
    XCTAssertEqual(Symbols.benchRole("closure #1 () -> () in closure #2 @Swift.MainActor (PerfLoopHost.Run) async throws -> () in DeskBench", benchModules: m), .driver)
    XCTAssertEqual(Symbols.benchRole("(extension in DeskBench):CapcomdDesk.Model.count() -> Swift.Int", benchModules: m), .bench)
    XCTAssertEqual(Symbols.benchRole("CapcomdDesk.ReelView.slide() -> ()", benchModules: m), .other)
    XCTAssertEqual(Symbols.benchRole("static PerfLoopHost.Ink.capture(__C.NSView, __C.CGRect) -> PerfLoopHost.Snapshot.Pixels?", benchModules: []), .bench)
    XCTAssertEqual(Symbols.benchRole("DeskBenchKit.Thing.f() -> ()", benchModules: m), .other, "a module that only starts with the name isn't it")
  }

  func testBenchSamplesAreThoseWhoseNearestOwnFrameIsTheBenchs() {
    let trunk = [StackFrame("CFRunLoopRunSpecific"), StackFrame("PerfLoopHost.Run.step", ours: true)]
    let action = StackFrame("closure #1 in closure #2 in DeskBench", ours: true, driver: true)
    let ink = StackFrame("Drive.inkOpened", ours: true, bench: true)
    // Leaf first.
    let stacks: [[StackFrame]] = Array(repeating: [StackFrame("-[NSView cacheDisplayInRect:toBitmapImageRep:]"), ink, action] + trunk.reversed(), count: 9)
      + [[StackFrame("objc_msgSend"), StackFrame("ListModel.rank", ours: true), action] + trunk.reversed()]   // the app's, under the action
      + [[StackFrame("CA::Transaction::commit")] + trunk.reversed()]                                         // a commit: nobody's
    let p = StackProfile(stacks: stacks)
    XCTAssertEqual(p.benchSamples, 9); XCTAssertEqual(p.bench.first, SymbolCount(symbol: "Drive.inkOpened", samples: 9))
  }

  func testExplainWarnsWhenAStepsWorstStretchIsBenchCode() throws {
    let rep = try PLJSON.decode(JSONValue.self, from: Data("""
      { "steps": [{}], "cpuMsPerStep": 4, "worstStretches": [ { "step": "toggle#0 open", "durationMs": 120, "samples": 110, "benchSamples": 100,
        "topBench": [ { "symbol": "Drive.inkOpened", "samples": 100 } ], "topOurs": [ { "symbol": "Drive.inkOpened", "samples": 100 } ] } ] }
      """.utf8))
    let s = Readings.side(rep: rep, metric: cpu)
    XCTAssertEqual(s.worstStretch?.benchPct, 90.9)
    let w = Explain.benchWarnings([s])
    XCTAssertEqual(w.count, 1)
    XCTAssertTrue(w[0].hasPrefix("warning: 90.9 % of the worst stretch (toggle#0 open) is the bench's own code, not the app's (Drive.inkOpened ×100): the bench measured itself"), w[0])
    var small = s; small.worstStretch?.benchPct = 10
    XCTAssertTrue(Explain.benchWarnings([small]).isEmpty)
  }
}

import XCTest
@testable import PerfLoopKit

/// Correctness guards in the acceptance rule (C6): pure, on made-up pairs.
final class GuardTests: XCTestCase {
  let guards = ["checks", "built-within", "snapshot-diff"]
  let ok = GuardResult(name: "built-within", pass: true, detail: "built")
  let blank = GuardResult(name: "built-within", pass: false, detail: "agt-1: no ColumnThread body")
  let same = GuardResult(name: "snapshot-diff", pass: true, detail: "0 %", value: 0)
  let differs = GuardResult(name: "snapshot-diff", pass: false, detail: "12 % differ", artifacts: ["a.png", "b.png"], value: 0.12, review: true)

  func guarded(_ ps: [Pair], a: [GuardResult], b: [GuardResult]) -> [Pair] { ps.map { var p = $0; p.a.guards = a; p.b.guards = b; return p } }

  func testCorrectnessGuardsComeFromTheManifestAndChecksAlwaysVeto() {
    XCTAssertEqual(GuardNames.correctness(ScenarioEntry(name: "s", kind: "smooth", objective: nil, guards: ["hitchTimeRatioMsPerS", "longestStretchMs"])), ["checks"],
                   "a Phase 2 deskbench listed its frame metrics as guards: its checks still veto")
    XCTAssertEqual(GuardNames.correctness(ScenarioEntry(name: "s", kind: "smooth", objective: nil, guards: guards)), guards)
    XCTAssertEqual(GuardNames.correctness(nil), ["checks"])
    XCTAssertEqual(GuardNames.adapterRun(guards), ["built-within", "snapshot-diff"])
    XCTAssertEqual(GuardNames.params(["built-within.ms": .number(300), "snapshot-diff.tolerance": .number(0.005)]), "built-within.ms=300,snapshot-diff.tolerance=0.005")
  }

  func testABlankColumnLosesAlthoughItIsFaster() {
    let ps = guarded(pairs(3, a: 40, b: 4, seed: 1), a: [ok, same], b: [blank, differs])
    let s = Acceptance.screen(ps, metric: "mainThreadCpuMsPerStep", guards: guards)
    XCTAssertEqual(s.wins, 3); XCTAssertEqual(s.verdict, "rejected")
    XCTAssertEqual(s.guardFailures.count, 3); XCTAssertEqual(s.guardReviews?.count, 3)
    let f = Acceptance.full(guarded(pairs(5, a: 40, b: 4, seed: 2), a: [ok, same], b: [blank, same]), metric: "mainThreadCpuMsPerStep", guards: guards, lastLook: false)
    XCTAssertEqual(f.verdict, "lost"); XCTAssertTrue(f.reasons.contains { $0.hasPrefix("built-within failed on the candidate") })
  }

  func testASnapshotOverToleranceIsNeverAWin() {
    let s = Acceptance.screen(guarded(pairs(3, a: 40, b: 20, seed: 3), a: [ok, same], b: [ok, differs]), metric: "mainThreadCpuMsPerStep", guards: guards)
    XCTAssertEqual(s.verdict, "needsReview"); XCTAssertTrue(s.guardsPassed)
    XCTAssertTrue(s.reasons.contains { $0.hasPrefix("needs review: snapshot-diff in pair 1") }, "\(s.reasons)")
    let f = Acceptance.full(guarded(pairs(5, a: 40, b: 20, seed: 4), a: [ok, same], b: [ok, differs]), metric: "mainThreadCpuMsPerStep", guards: guards, lastLook: false)
    XCTAssertEqual(f.verdict, "needsReview")
    // Without the review the same numbers win; a guard the manifest doesn't list doesn't count.
    XCTAssertEqual(Acceptance.full(guarded(pairs(5, a: 40, b: 20, seed: 4), a: [ok, same], b: [ok, same]), metric: "mainThreadCpuMsPerStep", guards: guards, lastLook: false).verdict, "won")
    XCTAssertEqual(Acceptance.full(guarded(pairs(5, a: 40, b: 20, seed: 4), a: [ok, same], b: [ok, differs]), metric: "mainThreadCpuMsPerStep", guards: ["checks"], lastLook: false).verdict, "won")
  }

  func testAGuardTheChampionFailsTooOrDropsDoesNotVetoButOneTheCandidateDropsDoes() {
    let both = Acceptance.guardFailures(guarded(pairs(3, a: 40, b: 20, seed: 5), a: [blank], b: [blank]), guards: guards)
    XCTAssertEqual(both, [], "the champion fails it as well: the guard says nothing about the candidate")
    let dropped = Acceptance.guardFailures(guarded(pairs(1, a: 40, b: 20, seed: 6), a: [ok, same], b: [same]), guards: guards)
    XCTAssertEqual(dropped, ["built-within not reported by the candidate in pair 1 (the champion's manifest asks for it)"])
  }

  func testGuardsAreReadFromRunsAndAbOutput() throws {
    let rep = JSONValue.object(["steps": .array([]), "guards": .array([.object(["name": .string("built-within"), "pass": .bool(false), "detail": .string("x"), "value": .number(12)])])])
    XCTAssertEqual(Readings.side(rep: rep, metric: "latencyMs").guards, [GuardResult(name: "built-within", pass: false, detail: "x", value: 12)])
    let ab = try PLJSON.decode(JSONValue.self, from: Data("""
      { "summaryA": { "reps": 1, "mainThreadCpuMsPerStep": { "median": 40 } }, "summaryB": { "reps": 1, "mainThreadCpuMsPerStep": { "median": 4 } },
        "guardsA": [ { "name": "snapshot-diff", "pass": true, "detail": "captured", "artifacts": ["/x/A/s.png"], "extra": 1 } ] }
      """.utf8))
    XCTAssertEqual(Readings.sides(ab: ab, label: "A", metric: "mainThreadCpuMsPerStep").first?.guards?.first?.artifacts, ["/x/A/s.png"])
    XCTAssertNil(Readings.sides(ab: ab, label: "B", metric: "mainThreadCpuMsPerStep").first?.guards, "no guards asked: none read")
  }

  func testAnExperimentWithGuardsRoundTripsAndOldOnesDecode() throws {
    var e = Experiment(id: "0007", hypothesis: "h", scenario: "step", fixture: "crew17", parent: nil, build: nil)
    let p = guarded(pairs(1, a: 40, b: 20, seed: 7), a: [ok], b: [differs])[0]
    e.isolation = [IsolationGuard(scenario: "burst", pair: p, pass: true, failures: [])]
    e.guardRuns = [GuardRun(pair: p, isolation: [], params: ["snapshot-diff.tolerance": .number(0.01)], override: "by the owner", failures: [], reviews: ["r"])]
    let back = try PLJSON.decode(Experiment.self, from: Data(PLJSON.encode(e).utf8))
    XCTAssertEqual(back, e); XCTAssertFalse(back.guardRuns![0].pass)
    var old = try JSONSerialization.jsonObject(with: Data(PLJSON.encode(Experiment(id: "0001", hypothesis: "h", scenario: "step", fixture: "crew17", parent: nil, build: nil)).utf8)) as! [String: Any]
    old.removeValue(forKey: "isolation")
    XCTAssertNil(try PLJSON.decode(Experiment.self, from: JSONSerialization.data(withJSONObject: old)).isolation)
    let text = Explain.experiment(back, champion: nil)
    XCTAssertTrue(text.contains("isolation burst: holds")); XCTAssertTrue(text.contains("guards re-run 1"))
  }
}

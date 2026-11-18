import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// Looks in the loop (v5, v11) against the fake adapter: regions the agent declares with `--expect-look` pass as
/// declared and keep their pictures for the PR's reviewer, a change elsewhere still asks the owner; a look parameter
/// the adapter can't apply is refused; each look has its own baseline.
final class LooksLoopTests: FakeBenchCase {
  override func tearDownWithError() throws { unsetenv("FAKE_LOOKS"); try super.tearDownWithError() }

  func feature(_ expect: [String], same: Bool = true) throws -> Experiment {
    try baseline(["GUARDED": "1"])
    setenv("FAKE_LOOKS", "footer", 1)
    var o = Loop.NewOptions(hypothesis: "the footer says how many items there are")
    o.bench = try bench("look", ["CPU": "40", "SNAP": "other", "GUARDED": "1"])
    o.expect = same ? "same" : nil; o.expectLook = expect
    return try loop.new(o)
  }

  func testADeclaredLookChangePassesForThePRsReviewerWithItsPictures() throws {
    let e = try feature(["footer"])
    XCTAssertEqual(e.expectLook, ["footer"]); XCTAssertFalse(e.behaviourChange, "a feature check moves no champion")
    let s = try XCTUnwrap(e.screen)
    XCTAssertNil(s.guardReviews, "\(s.reasons)")
    XCTAssertEqual(s.declaredLooks?.count, 3)
    XCTAssertTrue(s.reasons.contains { $0.hasPrefix("declared look (the PR's reviewer accepts it): snapshot-diff in pair 1: footer differs") }, "\(s.reasons)")
    let g = try XCTUnwrap(s.pairs[0].b.guards?.first { $0.name == "snapshot-diff" })
    XCTAssertTrue(g.pass); XCTAssertNil(g.review)
    let footer = try XCTUnwrap(g.looks?.first { $0.name == "footer" })
    XCTAssertEqual(footer.expected, true)
    // The pictures stay, store-relative: the whole windows and the region's before, after and diff.
    XCTAssertEqual(g.artifacts.count, 3)
    XCTAssertEqual(footer.pictures.count, 3)
    for p in g.artifacts + footer.pictures { XCTAssertFalse(p.hasPrefix("/"), p); XCTAssertTrue(FileManager.default.fileExists(atPath: store.abs(p)), p) }
    let text = loop.explain(e)
    XCTAssertTrue(text.contains("expect look: footer"), text)
    XCTAssertTrue(text.contains("snapshot-diff ✓ declared look"), text)
    XCTAssertTrue(text.contains("look footer differs") && text.contains("[declared]") && text.contains("look at (snapshot footer): exp/"), text)
    XCTAssertTrue(Explain.next(e).contains("the declared look change goes in the PR"), Explain.next(e))
  }

  func testAChangeOutsideTheDeclaredRegionsStillAsksTheOwner() throws {
    let e = try feature(["sidebar"])
    let s = try XCTUnwrap(e.screen)
    XCTAssertEqual(s.guardReviews?.count, 3, "\(s.reasons)"); XCTAssertNil(s.declaredLooks)
    let g = try XCTUnwrap(s.pairs[0].b.guards?.first { $0.name == "snapshot-diff" })
    XCTAssertEqual(g.review, true)
    XCTAssertTrue(g.detail.contains("declared sidebar but no region has that name"), g.detail)
    XCTAssertTrue(loop.explain(e).contains("look footer differs") && loop.explain(e).contains("not declared: the owner reviews it"), loop.explain(e))
  }

  func testInTheOptimisationLoopADeclaredLookIsABehaviourChange() throws {
    let e = try feature(["footer"], same: false)
    XCTAssertTrue(e.behaviourChange)
    XCTAssertTrue(e.notes.contains { $0.contains("--expect-look declares a look change") }, "\(e.notes)")
  }

  func testALookTheAdapterCantApplyIsRefused() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "dark"); o.bench = try bench("c", ["CPU": "20"]); o.params = ["appearance": "dark"]
    XCTAssertThrowsError(try loop.new(o)) { XCTAssertTrue("\($0)".contains("applies no appearance"), "\($0)") }
    var r = Loop.MeasureOptions(target: try bench("d", ["CPU": "20"])); r.scenario = "step"; r.params = ["textSize": "xLarge"]
    XCTAssertThrowsError(try loop.runScenario(r)) { XCTAssertTrue("\($0)".contains("applies no text size"), "\($0)") }
  }

  func testEachLookHasItsOwnBaseline() throws {
    try baseline()
    let cand = try bench("cand", ["EXTRA": "toggle", "CPU": "20", "APPEARANCES": "light,dark,system"])
    var o = Loop.MeasureOptions(target: cand, kind: "baseline"); o.scenario = "toggle"; o.reps = 1; o.params = ["appearance": "dark"]
    _ = try loop.runScenario(o)
    let dark = try XCTUnwrap(store.baseline("toggle", look: "dark"))
    XCTAssertEqual(dark.look, "dark"); XCTAssertEqual(dark.snapshot, "baselines/toggle~dark/reference.png")
    XCTAssertNil(store.baseline("toggle"), "light has none yet")
    var light = Loop.MeasureOptions(target: cand); light.scenario = "toggle"; light.reps = 1
    XCTAssertNil(try loop.runScenario(light).againstBaseline, "a light run isn't compared with the dark baseline")
    var d = light; d.params = ["appearance": "dark"]
    let r = try loop.runScenario(d)
    XCTAssertEqual(r.againstBaseline?.measurement, dark.measurement)
    XCTAssertEqual(r.snapshot?.pass, true)
    XCTAssertTrue(Measure.text(r).contains("look: dark"), Measure.text(r))
  }
}

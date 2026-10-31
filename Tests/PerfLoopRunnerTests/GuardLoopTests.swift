import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// Correctness guards in the loop (C6) against the fake adapter: the champion's guards asked of both sides, the
/// snapshots compared by the champion's snapdiff, a cheat rejected although it is faster, a snapshot over tolerance
/// sent to the owner, the isolation scenarios on every promotion.
final class GuardLoopTests: FakeBenchCase {
  func guarded(_ values: [String: String] = [:]) throws -> Store.Entry { try baseline(["GUARDED": "1"].merging(values) { $1 }) }

  func testACheatIsRejectedByGuardsAlthoughItsObjectiveWins() throws {
    try guarded()
    var o = Loop.NewOptions(hypothesis: "leave the columns blank")
    o.bench = try bench("cheat", ["CPU": "4", "BLANK": "1", "SNAP": "blank", "GUARDED": "1"])
    let e = try loop.new(o)
    let s = try XCTUnwrap(e.screen)
    XCTAssertEqual(s.wins, 3, "the objective wins every pair"); XCTAssertGreaterThan(s.medianGainPct ?? 0, 80)
    XCTAssertEqual(e.state, .rejected)
    XCTAssertFalse(s.guardsPassed)
    XCTAssertTrue(s.guardFailures.allSatisfy { $0.hasPrefix("built-within failed on the candidate") }, "\(s.guardFailures)")
    XCTAssertEqual(s.guardReviews?.count, 3, "and every snapshot differs")
    // Both sides were asked for the champion's guards, with its parameters.
    XCTAssertTrue(adapterCalls("ab").allSatisfy { $0.contains("guards=built-within,snapshot-diff") && $0.contains("snapshot-diff.tolerance=0.005") })
    XCTAssertEqual(adapterCalls("snapdiff").count, 3)
    // The failing pictures stay for the owner (store-relative), the .later ones go.
    let snap = try XCTUnwrap(s.pairs[0].b.guards?.first { $0.name == "snapshot-diff" })
    XCTAssertEqual(snap.review, true); XCTAssertEqual(snap.artifacts.count, 3)
    for a in snap.artifacts { XCTAssertTrue(FileManager.default.fileExists(atPath: store.abs(a)), a); XCTAssertFalse(a.hasPrefix("/")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.abs(snap.artifacts[0]).replacingOccurrences(of: ".png", with: ".later.png")))
    let text = try String(contentsOfFile: store.abs("exp/\(e.id)/explain.txt"), encoding: .utf8)
    XCTAssertTrue(text.contains("guards pair 1: built-within ✗ 12 ms, snapshot-diff REVIEW 20.0 %"), text)
    // Not even forced through a full is it a win.
    XCTAssertEqual(try loop.full(e.id, force: true).state, .lost)
    XCTAssertThrowsError(try loop.promote(e.id)) { XCTAssertEqual(($0 as? PLError)?.code, 6) }
  }

  func testAnHonestRebuildPassesItsGuardsAndPassingPicturesAreDeleted() throws {
    try guarded()
    var o = Loop.NewOptions(hypothesis: "faster, same pixels"); o.bench = try bench("good", ["CPU": "8", "GUARDED": "1"])
    let e = try loop.new(o)
    XCTAssertEqual(e.state, .promising, "\(e.screen!.reasons)")
    XCTAssertNil(e.screen?.guardReviews); XCTAssertTrue(e.screen!.guardsPassed)
    let snap = try XCTUnwrap(e.screen?.pairs[0].b.guards?.first { $0.name == "snapshot-diff" })
    XCTAssertTrue(snap.pass); XCTAssertEqual(snap.artifacts, [])
    let pngs = FileManager.default.enumerator(atPath: store.abs("exp/\(e.id)"))!.compactMap { $0 as? String }.filter { $0.hasSuffix(".png") }
    XCTAssertEqual(pngs, [], "passing snapshots are deleted")
  }

  func testASnapshotOverToleranceNeedsTheOwnerWhoMayAcceptIt() throws {
    try guarded()
    var o = Loop.NewOptions(hypothesis: "a new font"); o.bench = try bench("look", ["CPU": "8", "SNAP": "other", "GUARDED": "1"])
    var e = try loop.new(o)
    XCTAssertEqual(e.state, .needsReview, "\(e.screen!.reasons)")
    XCTAssertEqual(e.screen?.verdict, "needsReview")
    XCTAssertTrue(Explain.next(e).contains("perfloop guards --exp \(e.id) --guard-tolerance X --owner"))
    // The agent can't loosen the tolerance, nor run the full.
    XCTAssertThrowsError(try loop.guards(e.id, tolerance: 0.3)) { XCTAssertEqual(($0 as? PLError)?.code, 6) }
    XCTAssertThrowsError(try loop.full(e.id))
    // A re-run without a new tolerance still asks; the owner's tolerance clears it and holds for the full.
    let (_, again) = try loop.guards(e.id)
    XCTAssertFalse(again.pass); XCTAssertEqual(again.reviews.count, 1)
    loop.by = "owner"
    let (cleared, run) = try loop.guards(e.id, tolerance: 0.3)
    XCTAssertTrue(run.pass, "\(run.failures) \(run.reviews)"); XCTAssertEqual(cleared.state, .promising)
    XCTAssertEqual(run.override, "snapshot-diff.tolerance 0.3 by the owner"); XCTAssertEqual(run.isolation.map(\.scenario), ["burst"])
    loop.by = "agent"
    e = try loop.full(e.id)
    XCTAssertEqual(e.state, .won, "\(e.full!.reasons)")
    XCTAssertTrue(adapterCalls("snapdiff").suffix(5).allSatisfy { $0.hasSuffix("tol=0.3") })
  }

  func testIsolationGuardsRunOnEveryPromotion() throws {
    try guarded()
    var o = Loop.NewOptions(hypothesis: "breaks isolation"); o.bench = try bench("leaky", ["CPU": "8", "ISO_FAIL": "1", "GUARDED": "1"]); o.screen = false
    var bad = try loop.new(o)
    bad = try loop.screen(bad.id)
    XCTAssertEqual(bad.state, .promising, "step itself is fine")
    bad = try loop.full(bad.id)
    XCTAssertEqual(bad.state, .lost)
    XCTAssertEqual(bad.isolation?.first?.scenario, "burst"); XCTAssertEqual(bad.isolation?.first?.pass, false)
    XCTAssertTrue(bad.notes.contains { $0.hasPrefix("isolation broken in burst: isolation-still failed on the candidate") }, "\(bad.notes)")
    XCTAssertTrue(adapterCalls("ab").contains { $0.hasPrefix("ab burst crew17") && $0.contains("guards=built-within") })

    var g = Loop.NewOptions(hypothesis: "keeps isolation"); g.bench = try bench("tidy", ["CPU": "8", "GUARDED": "1"])
    var good = try loop.full(try loop.new(g).id)
    XCTAssertEqual(good.state, .won); XCTAssertEqual(good.isolation?.map(\.pass), [true])
    good = try loop.promote(good.id)
    XCTAssertEqual(good.state, .promoted)
    let text = try String(contentsOfFile: store.abs("exp/\(good.id)/explain.txt"), encoding: .utf8)
    XCTAssertTrue(text.contains("isolation burst: holds"), text)
  }

  func testACandidateCannotDropAGuard() throws {
    try guarded()
    var o = Loop.NewOptions(hypothesis: "a bench that forgot its guards"); o.bench = try bench("noguards", ["CPU": "8", "NOGUARDS": "1", "GUARDED": "1"])
    let e = try loop.new(o)
    XCTAssertEqual(e.state, .rejected)
    XCTAssertTrue(e.screen!.guardFailures.contains { $0.contains("built-within not reported by the candidate") }, "\(e.screen!.guardFailures)")
  }

  func testAKnobExperimentGetsGuardsThroughRun() throws {
    let base = try store.add(try bench("base", ["CPU": "40", "GUARDED": "1", "CLIP_DIV": "2"]))
    try loop.setChampion(build: base.build.hash!, merged: true, scenario: "step", fixture: "crew17")
    var o = Loop.NewOptions(hypothesis: "clip"); o.knobs = ["reel.slide": "clip"]
    let e = try loop.new(o)
    XCTAssertEqual(e.via, "run"); XCTAssertEqual(e.state, .promising, "\(e.screen!.reasons)")
    XCTAssertEqual(adapterCalls("run").count, 6)
    XCTAssertTrue(adapterCalls("run").allSatisfy { $0.contains("guards=built-within,snapshot-diff") })
    XCTAssertEqual(adapterCalls("snapdiff").count, 3, "one binary, two settings: the pictures are still compared")
    XCTAssertTrue(adapterCalls("snapdiff")[0].contains("/screen/p1/a/step-rep0.settled.png") && adapterCalls("snapdiff")[0].contains("/screen/p1/b/"))
  }
}

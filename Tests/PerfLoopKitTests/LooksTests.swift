import XCTest
@testable import PerfLoopKit

/// Looks (v5, v11), the pure part: judging a snapshot-diff's regions against the declared ones, the look keys, and
/// reading the records back.
final class LooksTests: XCTestCase {
  func guardWith(_ looks: [RegionLook]) -> GuardResult {
    GuardResult(name: "snapshot-diff", pass: false, detail: "", artifacts: ["a.png", "b.png"], value: 0.012, limit: 0.005, review: true, looks: looks)
  }

  func testDeclaredRegionsPassAndTheRestReviews() {
    let g = guardWith([RegionLook(name: "footer", look: "differs", share: 0.2, before: "f.before.png", after: "f.after.png", diff: "f.diff.png"),
                       RegionLook(name: "list", look: "moved", share: 0.3, movedPt: [60, 0]), RegionLook(name: "rest", look: "same", share: 0)])
    let none = Looks.judge(g, expected: [])
    XCTAssertFalse(none.pass); XCTAssertEqual(none.review, true)
    XCTAssertTrue(none.detail.hasPrefix("footer differs 20.0 % · list moved 60,0 pt; same: rest"), none.detail)
    let part = Looks.judge(g, expected: ["footer"])
    XCTAssertFalse(part.pass, "the list moved and nobody declared it")
    XCTAssertEqual(part.looks?.first?.expected, true); XCTAssertNil(part.looks?[1].expected)
    let all = Looks.judge(g, expected: ["footer", "list", "sidebar"])
    XCTAssertTrue(all.pass); XCTAssertNil(all.review)
    XCTAssertTrue(all.detail.contains("declared sidebar but no region has that name"), all.detail)
    XCTAssertTrue(all.detail.contains("only where declared"), all.detail)
    // Each changed region with what to look at, and whose call it is.
    let lines = Looks.lines(part)
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].contains("look footer differs 20.0 % [declared] · declared by the agent") && lines[0].hasSuffix("look at: f.after.png  f.diff.png  f.before.png"), lines[0])
    XCTAssertTrue(lines[1].contains("not declared: the owner reviews it"), lines[1])
    // A guard without regions (an older adapter, two looks that can't compare) keeps its own verdict.
    let old = GuardResult(name: "snapshot-diff", pass: false, detail: "x", review: true)
    XCTAssertEqual(Looks.judge(old, expected: ["footer"]), old)
    // Unchanged: the same in every region.
    XCTAssertTrue(Looks.judge(guardWith([RegionLook(name: "window", look: "same")]), expected: []).pass)
  }

  func testLookKeysAndNames() {
    XCTAssertNil(Looks.key(nil)); XCTAssertNil(Looks.key(["appearance": "light"])); XCTAssertNil(Looks.key(["rows": "10"]))
    XCTAssertEqual(Looks.key(["appearance": "dark"]), "dark")
    XCTAssertEqual(Looks.key(["textSize": "xLarge"]), "light-text-xLarge")
    XCTAssertEqual(Looks.key(["appearance": "dark", "textSize": "xLarge"]), "dark-text-xLarge")
    XCTAssertEqual(Looks.names(["footer, list", "footer", "", "rest"]), ["footer", "list", "rest"])
    XCTAssertEqual(Looks.layoutPath("/x/a.settled.png"), "/x/a.settled.layout.json"); XCTAssertEqual(Looks.laterPath("/x/a.png"), "/x/a.later.png")
    XCTAssertEqual(Looks.fileName("child 1/x"), "child-1-x")
  }

  func testRecordsReadBackAndAManifestSaysWhatItApplies() throws {
    var l = SnapshotLayout(size: [200, 100], scale: 2, appearance: "dark", regions: [.init(name: "footer", rect: [0, 80, 200, 20], source: "identifier")])
    l.childWindows = [.init(name: "details", kind: "NSPanel", rect: [10, 10, 50, 30], material: true)]
    XCTAssertEqual(try PLJSON.decode(SnapshotLayout.self, from: Data(PLJSON.encode(l).utf8)), l)
    let g = guardWith([RegionLook(name: "footer", look: "differs", share: 0.2)])
    let v = try PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(g).utf8))
    XCTAssertEqual(GuardResult(json: v), g)
    XCTAssertNil(try PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(GuardResult(name: "x", pass: true, detail: "")).utf8))["looks"], "absent when there are none")

    var m = Manifest(app: "a", adapter: "b", build: nil, scenarios: [])
    XCTAssertNotNil(m.unsupportedLook(["appearance": "dark"], whose: "it"))
    XCTAssertNil(m.unsupportedLook(["rows": "10"], whose: "it"))
    m.appearances = ["light", "dark"]
    XCTAssertNil(m.unsupportedLook(["appearance": "dark"], whose: "it"))
    XCTAssertTrue(m.unsupportedLook(["appearance": "sepia"], whose: "it")?.contains("isn't one it applies") == true)
    XCTAssertTrue(m.unsupportedLook(["textSize": "large"], whose: "it")?.contains("applies no text size") == true)
    let back = try PLJSON.decode(Manifest.self, from: Data(PLJSON.encode(m).utf8))
    XCTAssertEqual(back.appearances, ["light", "dark"]); XCTAssertNil(back.textSizes)
  }
}

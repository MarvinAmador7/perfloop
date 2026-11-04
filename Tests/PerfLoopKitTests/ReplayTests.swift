import XCTest
@testable import PerfLoopKit

/// docs/design/replay.json (SPEC §6.1) decodes and its budget meets the replay's acceptance: at most a third
/// of the session's bench minutes.
final class ReplayTests: XCTestCase {
  static let plan = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/design/replay.json")

  func testThePlanDecodesAndFitsTheBudget() throws {
    let p = try PLJSON.read(ReplayPlan.self, path: Self.plan.path)
    XCTAssertEqual(p.builds.map(\.name), ["base", "v1", "v2", "v3", "v4", "v5"])
    XCTAssertEqual(p.champion, "base")
    for s in p.steps where s.do == "exp" { XCTAssertNotNil(p.build(s.build ?? ""), "step builds name a build") }
    let b = p.budget
    XCTAssertEqual([b.screens, b.fulls, b.confirmations, b.diffs], [6, 3, 2, 2])  // SPEC §6.1's budget
    XCTAssertEqual(b.seconds, 930); XCTAssertTrue(b.withinThird)
    let text = p.dryRun(exists: { _ in true })
    XCTAssertTrue(text.contains("6 screens")); XCTAssertTrue(text.contains("within")); XCTAssertTrue(text.contains("not run (--dry-run)"))
    XCTAssertTrue(p.dryRun(exists: { !$0.hasSuffix("v2-dir") }).contains("cannot run: missing builds v2"))
  }
}

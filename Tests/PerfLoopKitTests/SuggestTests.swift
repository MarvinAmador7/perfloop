import XCTest
@testable import PerfLoopKit

/// `suggest` on hand-made results shaped like SlowList's slow path and capcomd's two-window bench bug (JOURNEY §5.4).
final class SuggestTests: XCTestCase {
  /// 8 steps of 66 ms: each selection re-evaluates Row×15 while 2 rows' content changes, and one function of ours,
  /// called from every Row body, holds the worst stretches.
  func slowList() -> JSONValue {
    let step: (Int) -> JSONValue = { i in
      .object(["name": .string("select#\(i)"), "cpuMs": .number(66), "bodies": .object(["Row": .number(15), "RowContent": .number(2)]),
               "causes": .array([.object(["keyPath": .string("ListModel.selection"), "count": .number(1),
                                          "bodies": .object(["Row": .number(15), "RowContent": .number(2)]), "objects": .object(["Row": .number(15), "RowContent": .number(2)])])])])
    }
    let worst: (Int) -> JSONValue = { i in
      .object(["step": .string("select#\(i)"), "durationMs": .number(66.5), "cpuMs": .number(65.5), "samples": .number(63),
               "topOurs": .array([.object(["symbol": .string("ListModel.rankBySorting"), "samples": .number(61)]),
                                  .object(["symbol": .string("RowView.body.getter"), "samples": .number(61)]),
                                  .object(["symbol": .string("closure #1 in UnsafeMutableBufferPointer._stableSortImpl"), "samples": .number(61)])]),
               "topFramework": .array([.object(["symbol": .string("AG::Graph::UpdateStack::update"), "samples": .number(62)])])])
    }
    return .object(["schema": .string("perfloop.result/2"),
                    "summary": .object(["objective": .object(["name": .string("mainThreadCpuMsPerStep"), "value": .number(65.2)]),
                                        "mainThreadCpuMsPerStep": .object(["median": .number(65.2)]), "hitchTimeRatioMsPerS": .object(["median": .number(296)]),
                                        "steadyHz": .object(["median": .number(60)])]),
                    "reps": .array([.object(["steps": .array((0..<8).map(step)), "worstStretches": .array([worst(2), worst(3), worst(5)])])])])
  }

  func testTheSlowPathsTwoFixesComeFirst() {
    let d = Suggest.make(result: slowList())
    XCTAssertEqual(d.schema, "perfloop.suggest/1")
    XCTAssertEqual(d.hypotheses.map(\.rule), ["hot-frame", "fan-out"], "\(d.hypotheses)")
    let hot = d.hypotheses[0], fan = d.hypotheses[1]
    XCTAssertTrue(hot.hypothesis.hasPrefix("ListModel.rankBySorting holds 97 % of the worst stretches under RowView.body.getter, once per RowView body (×15"), hot.hypothesis)
    XCTAssertEqual(hot.share ?? 0, 0.96, accuracy: 0.01)
    XCTAssertTrue(fan.hypothesis.contains("every Row re-evaluates when ListModel.selection changes although only ~2 of 15 need to"))
    XCTAssertEqual(fan.share ?? 0, 0.84, accuracy: 0.02)   // the steps' CPU × Row.body's share × (1 − 2/15)
    XCTAssertFalse(d.hypotheses.contains { $0.hypothesis.contains("UnsafeMutableBufferPointer") || $0.hypothesis.contains("AG::") }, "plumbing is never the cause")
    XCTAssertTrue(Suggest.text(d).contains("1. [hot-frame, up to 96 %]"))
  }

  /// Every body twice per instance per update: capcomd's bench drew two windows on one model.
  func testTwoBodiesPerInstanceSaysLookForASecondHost() {
    let r: JSONValue = .object(["reps": .array([.object(["steps": .array([.object(["name": .string("step#0"), "cpuMs": .number(180),
      "causes": .array([.object(["keyPath": .string("DeskModel.focused"), "count": .number(1), "bodies": .object(["Column": .number(34)]), "objects": .object(["Column": .number(17)])])])])])])])])
    let d = Suggest.make(result: r)
    let h = d.hypotheses.first { $0.rule == "repeated-body" }
    XCTAssertNotNil(h); XCTAssertTrue(h?.hypothesis.contains("Column's body runs 2.0× per instance") == true)
    XCTAssertTrue(h?.check.contains("two-window") == true)
    XCTAssertTrue(d.notes.contains { $0.contains("no sampled stacks") })
  }

  func testWaitingLatencyRenderingAndWalls() throws {
    let lat: JSONValue = .object(["summary": .object(["objective": .object(["name": .string("latencyMs")]), "latencyMs": .object(["median": .number(140)]),
                                                     "mainThreadCpuMsPerStep": .object(["median": .number(12)])]), "reps": .array([])])
    XCTAssertEqual(Suggest.make(result: lat).hypotheses.first?.rule, "waiting")
    let gpu: JSONValue = .object(["summary": .object(["mainThreadCpuMsPerStep": .object(["median": .number(1.5)]), "hitchTimeRatioMsPerS": .object(["median": .number(40)]),
                                                     "steadyHz": .object(["median": .number(120)])]), "reps": .array([])])
    XCTAssertEqual(Suggest.make(result: gpu).hypotheses.first?.rule, "frames-not-cpu")
    let axes = [SweepAxis(name: "rows", role: "fixture", values: ["100", "400", "700", "1000"])]
    let pts = axes[0].values.map { v -> SweepPoint in var p = SweepPoint(values: ["rows": v]); p.objective = 2 + 0.01 * Double(v)!; return p }
    var sw = SweepDoc(scenario: "select", fixture: "rows", objective: "mainThreadCpuMsPerStep", build: nil, axis: axes, reps: 1, points: pts)
    (sw.fit, sw.fits) = Sweep.fits(pts, axes: axes, objective: sw.objective)
    let walls = Suggest.make(result: nil, sweep: sw).hypotheses.filter { $0.rule == "wall" }
    XCTAssertEqual(walls.count, 2); XCTAssertTrue(walls[0].hypothesis.contains("rows ≈"))
    XCTAssertTrue(Suggest.make(result: .object(["reps": .array([])])).notes.contains { $0.contains("nothing stood out") })
  }
}

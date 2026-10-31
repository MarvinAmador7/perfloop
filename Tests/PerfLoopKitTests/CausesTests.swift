import XCTest
@testable import PerfLoopKit

/// `perfloop causes`: the cause records an adapter writes on its result (C7), read generically from the JSON.
final class CausesTests: XCTestCase {
  let result = """
  { "scenario": "step", "fixture": "crew17",
    "reps": [ { "index": 0,
      "steps": [
        { "name": "step#0 0→3", "durationMs": 380.8, "causes": [
          { "keyPath": "AgentSlice.focused", "count": 2, "ids": 2, "bodies": { "Column": 34, "CrewTab": 4 }, "objects": { "Column": 17, "CrewTab": 4 } },
          { "keyPath": "DeskModel.focusedAgent", "count": 1, "bodies": { "Column": 34, "CrewTab": 4 }, "objects": { "Column": 17, "CrewTab": 4 } },
          { "keyPath": "(unrecorded)", "count": 0, "bodies": { "Reel": 1 } } ] },
        { "name": "step#1 3→6", "durationMs": 377.0, "causes": [
          { "keyPath": "AgentSlice.focused", "count": 2, "ids": 2, "bodies": { "Column": 34 }, "objects": { "Column": 17 } } ] } ],
      "worstStretches": [
        { "step": "step#0 0→3", "durationMs": 38.5, "causes": [
          { "keyPath": "AgentSlice.focused", "count": 2, "ids": 2, "bodies": { "Column": 34 }, "objects": { "Column": 17 } } ] },
        { "step": "before step#0 0→3 (setup)", "durationMs": 590.0, "causes": [] } ] } ] }
  """

  func value(_ s: String) throws -> JSONValue { try PLJSON.decode(JSONValue.self, from: Data(s.utf8)) }

  func testTableSumsStepsPerKeyPath() throws {
    let t = try XCTUnwrap(CauseTable.table(try value(result)))
    XCTAssertEqual(t.reps, 1); XCTAssertEqual(t.perStep.count, 2)
    XCTAssertEqual(t.steps.first?.keyPath, "AgentSlice.focused")
    XCTAssertEqual(t.steps.first?.count, 4); XCTAssertEqual(t.steps.first?.bodies, ["Column": 68, "CrewTab": 4]); XCTAssertEqual(t.steps.first?.objects?["Column"], 17)
    XCTAssertEqual(t.stretches.map(\.durationMs), [590.0, 38.5])   // longest first
  }

  func testTextNamesTheMutationsAndTheBodies() throws {
    let s = CauseTable.text(try value(result))
    XCTAssertTrue(s.contains("causes in step on crew17, 1 rep"), s)
    XCTAssertTrue(s.contains("rep 0 step#0 0→3 (380.8 ms): AgentSlice.focused×2 + DeskModel.focusedAgent×1 → Column×34 (17 distinct), CrewTab×4 · (unrecorded) → Reel×1"), s)
    XCTAssertTrue(s.contains("38.5 ms  rep 0 during step#0 0→3: AgentSlice.focused×2 → Column×34 (17 distinct)"), s)
    XCTAssertTrue(s.contains("590 ms  rep 0 before step#0 0→3 (setup): no bodies"), s)
  }

  func testAResultWithoutCausesSaysSo() throws {
    let v = try value(#"{ "scenario": "step", "reps": [ { "steps": [ { "name": "s" } ], "worstStretches": [] } ] }"#)
    XCTAssertNil(CauseTable.table(v))
    XCTAssertTrue(CauseTable.text(v).contains("no causes recorded"))
  }

  func testTheWorstStretchNoteCarriesItsCauses() throws {
    let rep = try XCTUnwrap(try value(result)["reps"]?[0])
    let s = Readings.side(rep: rep, metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(s.worstStretch?.durationMs, 590)
    XCTAssertEqual(s.worstStretch?.causes, "no bodies")
    let older = try value(#"{ "steps": [], "worstStretches": [ { "durationMs": 12, "step": "x" } ] }"#)
    XCTAssertNil(Readings.side(rep: older, metric: "mainThreadCpuMsPerStep").worstStretch?.causes)
  }
}

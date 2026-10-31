import XCTest
@testable import PerfLoopKit

/// Recorded gestures on the runner's side (C9): listing gesture files, reading smoothness out of results, and the
/// full stage's guards on it.
final class GestureTests: XCTestCase {
  func file(_ events: String, schema: String = "perfloop.gesture/1") throws -> JSONValue {
    try PLJSON.decode(JSONValue.self, from: Data("""
    { "schema": "\(schema)", "name": "flick", "device": "trackpad", "hz": 120, "synthetic": true, "events": [\(events)] }
    """.utf8))
  }

  func testAGestureFileIsSummedUpAndCheckedLoosely() throws {
    let g = GestureFile(path: "/x/flick.json", json: try file("""
      { "t": 0, "dx": 0, "dy": 0, "phase": "began", "momentum": "none", "precise": true },
      { "t": 8.3, "dx": -12, "dy": 1, "phase": "changed", "momentum": "none", "precise": true, "future": 1 },
      { "t": 16.7, "dx": 0, "dy": 0, "phase": "ended", "momentum": "none", "precise": true },
      { "t": 25, "dx": -20, "dy": 0, "phase": "none", "momentum": "began", "precise": true }
    """))
    XCTAssertEqual(g.problems, []); XCTAssertEqual(g.events, 4); XCTAssertEqual(g.durationMs, 25)
    XCTAssertEqual(g.finger, [-12, 1]); XCTAssertEqual(g.momentum, [-20, 0]); XCTAssertTrue(g.synthetic)
    XCTAssertTrue(g.line.contains("fingers -12.0, 1.0 pt"))
    let bad = GestureFile(path: "/x/b.json", json: try file(#"{ "t": 5, "dx": 0, "phase": "began" }, { "t": 1, "dx": 0, "phase": "ended" }"#, schema: "perfloop.result/2"))
    XCTAssertEqual(bad.problems.count, 3, "\(bad.problems)")
  }

  func testScanListsGestureFilesAndSkipsOtherJSON() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-gestures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try PLJSON.encode(try file(#"{ "t": 0, "dx": -3, "phase": "changed", "momentum": "none" }"#)).write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
    try #"{ "schema": "perfloop.result/2" }"#.write(to: dir.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
    let found = GestureFile.scan(dirs: [dir.path], files: [dir.appendingPathComponent("a.json").path])
    XCTAssertEqual(found.count, 1, "a file named and in a folder is listed once; another schema is skipped")
    XCTAssertEqual(GestureFile.scan(dirs: [dir.path]).map(\.name), ["flick"])
  }

  func testReadingsTakeSmoothnessFromRepsAndSummaries() throws {
    let rep = try PLJSON.decode(JSONValue.self, from: Data(#"{ "steps": [{ "cpuMs": 3 }], "smoothness": { "positionErrorP95Pt": 0.5, "stalls": 2, "jerkP95": 7.5 } }"#.utf8))
    let s = Readings.side(rep: rep, metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(s.positionErrorP95Pt, 0.5); XCTAssertEqual(s.stalls, 2); XCTAssertEqual(s.jerkP95, 7.5)
    let sum = try PLJSON.decode(JSONValue.self, from: Data(#"{ "smoothness": { "positionErrorP95Pt": { "median": 0.25 }, "stalls": { "median": 1 } } }"#.utf8))
    let t = Readings.side(summary: sum, metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(t.positionErrorP95Pt, 0.25); XCTAssertEqual(t.stalls, 1); XCTAssertNil(t.jerkP95)
    XCTAssertNil(Readings.side(rep: .object([:]), metric: "x").stalls, "no gesture, no smoothness")
  }

  /// A candidate that is faster but stops following the fingers loses on the gesture's guards; its jerk never decides.
  func testStallsGuardAFullAndJerkDoesNot() {
    func smooth(_ p: [Pair], errA: Double, errB: Double, stallsA: Double, stallsB: Double, jerkB: Double) -> [Pair] {
      p.map { var x = $0
        x.a.positionErrorP95Pt = errA; x.b.positionErrorP95Pt = errB; x.a.stalls = stallsA; x.b.stalls = stallsB; x.a.jerkP95 = 2; x.b.jerkP95 = jerkB
        return x }
    }
    let base = pairs(5, a: 62, b: 12.4, seed: 8)
    let ok = Acceptance.full(smooth(base, errA: 0, errB: 0, stallsA: 0, stallsB: 0, jerkB: 90), metric: "mainThreadCpuMsPerStep", guards: [], lastLook: false)
    XCTAssertEqual(ok.verdict, "won", "\(ok.reasons)"); XCTAssertEqual(ok.frameGuards?["stalls"]?.pass, true); XCTAssertNil(ok.frameGuards?["jerkP95"])
    let stalls = Acceptance.full(smooth(base, errA: 0, errB: 0, stallsA: 0, stallsB: 6, jerkB: 2), metric: "mainThreadCpuMsPerStep", guards: [], lastLook: false)
    XCTAssertEqual(stalls.verdict, "lost"); XCTAssertEqual(stalls.frameGuards?["stalls"]?.pass, false)
    let err = Acceptance.full(smooth(base, errA: 0, errB: 4, stallsA: 0, stallsB: 0, jerkB: 2), metric: "mainThreadCpuMsPerStep", guards: [], lastLook: false)
    XCTAssertEqual(err.frameGuards?["positionErrorP95Pt"]?.pass, false)
    // One stall more a rep is inside the band.
    XCTAssertEqual(Acceptance.full(smooth(base, errA: 0, errB: 0.4, stallsA: 0, stallsB: 1, jerkB: 2), metric: "mainThreadCpuMsPerStep", guards: [], lastLook: false).verdict, "won")
    // Scenarios that replay no gesture have no such guard.
    XCTAssertNil(Acceptance.full(base, metric: "mainThreadCpuMsPerStep", guards: [], lastLook: false).frameGuards?["stalls"])
  }

  func testTheManifestCarriesBuiltInGestures() throws {
    let m = try PLJSON.decode(Manifest.self, from: Data(#"{ "app": "a", "scenarios": [], "knobs": [], "fixtures": [], "gestures": ["synthetic:flick-forward"] }"#.utf8))
    XCTAssertEqual(m.gestures, ["synthetic:flick-forward"])
    XCTAssertNil(try PLJSON.decode(Manifest.self, from: Data(#"{ "app": "a" }"#.utf8)).gestures)
  }
}

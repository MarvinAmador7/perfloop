import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// `perfloop sweep` against Fixtures/fake-sweep-adapter.sh (CPU per step = 2 + 0.9 × agents + 0.01 × items, + 3 ms
/// with reel.slide=clip): the roles of `--set`, the grid, resume, the lock, the budget, busy points, the fit.
final class SweepRunTests: XCTestCase {
  static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-sweep-adapter.sh").path
  var tmp: URL!
  var log: URL { tmp.appendingPathComponent("adapter.log") }
  var r: SweepRun!
  var manifest: Manifest!

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-sweep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    r = SweepRun()
    r.log = { _ in }
    r.lockPollS = 0.05
    r.env = ProcessInfo.processInfo.environment.merging(["FAKE_LOG": log.path]) { $1 }
    manifest = try XCTUnwrap(Adapter(exe: Self.script).manifest())
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

  func runs() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
  func options(_ sets: [String], reps: Int = 2) -> SweepRun.Options {
    var o = SweepRun.Options(scenario: "step"); o.sets = sets; o.reps = reps; o.out = tmp.appendingPathComponent("sweep").path; return o
  }

  func testRolesComeFromTheManifest() throws {
    let p = try r.plan(exe: Self.script, manifest: manifest, options(["agents=4..16/4", "reel.slide=ca,clip", "steps=4"]), home: tmp)
    XCTAssertEqual(p.fixture, "crew")                                       // the parametric fixture, since agents is one of its parameters
    XCTAssertEqual(p.axes.map(\.role), ["fixture", "knob"]); XCTAssertEqual(p.fixed, ["steps": "4"])
    XCTAssertEqual(p.points.count, 8)
    let cmd = r.command(p, ["agents": "8", "reel.slide": "clip"])
    XCTAssertEqual(cmd, ["PERFLOOP_KNOBS=reel.slide=clip", "run", "step", "--fixture", "crew@agents=8", "--reps", "2", "--json", "--set", "steps=4"])
    XCTAssertThrowsError(try r.plan(exe: Self.script, manifest: manifest, options(["colour=1,2"]), home: tmp)) { e in
      XCTAssertTrue("\(e)".contains("not a knob (reel.slide), a parameter of fixture"), "\(e)")
    }
    XCTAssertThrowsError(try r.plan(exe: Self.script, manifest: manifest, options(["agents=64..256/64"]), home: tmp))       // outside 1…128
    XCTAssertThrowsError(try r.plan(exe: Self.script, manifest: manifest, options(["reel.slide=ca,spring"]), home: tmp))    // not a choice
    XCTAssertThrowsError(try r.plan(exe: Self.script, manifest: manifest, options(["steps=8"]), home: tmp))                 // nothing swept
    XCTAssertNoThrow(try r.plan(exe: Self.script, manifest: manifest, options(["param:colour=1,2"]), home: tmp))
  }

  func testDryRunPrintsTheGridAndAnEstimateWithoutRunning() throws {
    var o = options(["agents=4..64/12"]); o.repS = 5; o.startupS = 4
    let p = try r.plan(exe: Self.script, manifest: manifest, o, home: tmp)
    let t = r.dryRun(p, budgetMin: 1)
    XCTAssertTrue(t.contains("6 point(s), 0 done"), t)
    XCTAssertTrue(t.contains("run step --fixture crew@agents=64 --reps 2 --json"), t)
    XCTAssertTrue(t.contains("estimate: 6 point(s) × 14 s ≈ 84 s"), t)
    XCTAssertTrue(t.contains("budget: 1 min covers about 4 point(s)"), t)
    XCTAssertTrue(runs().isEmpty)
  }

  func testSweepFitsTheCostCurveAndResumes() throws {
    var o = options(["agents=4..64/12", "items=100"]); o.lock = tmp.appendingPathComponent("window.lock").path
    let p = try r.plan(exe: Self.script, manifest: manifest, o, home: tmp)
    let d = try r.run(p, o)
    XCTAssertTrue(d.complete)
    XCTAssertEqual(d.points.count, 6); XCTAssertEqual(runs().count, 6)
    XCTAssertTrue(runs().allSatisfy { $0.contains("reps=2") && $0.contains("items=100") })
    let f = try XCTUnwrap(d.fit)
    XCTAssertEqual(f.model, "linear"); XCTAssertEqual(f.slope, 0.9, accuracy: 0.01); XCTAssertGreaterThan(f.r2, 0.999)
    XCTAssertEqual(f.intercept, 3, accuracy: 0.1)                          // 2 + 0.01 × 100
    XCTAssertTrue(Sweep.text(d).contains("fit: ms/step grows 0.9 ms per agent (r² 1.0)"), Sweep.text(d))
    XCTAssertFalse(FileManager.default.fileExists(atPath: o.lock!))        // released after every point
    let doc = try PLJSON.read(SweepDoc.self, path: p.dir.appendingPathComponent("sweep.json").path)
    XCTAssertEqual(doc, d)
    XCTAssertEqual(doc.build?.commit, "abc1234")

    // The same command again: nothing to measure. --redo one point: only that one.
    let again = try r.plan(exe: Self.script, manifest: manifest, o, home: tmp)
    XCTAssertTrue(again.todo.isEmpty); XCTAssertFalse(again.estimated)
    _ = try r.run(again, o)
    XCTAssertEqual(runs().count, 6)
    var redo = o; redo.redo = ["agents=28"]
    _ = try r.run(try r.plan(exe: Self.script, manifest: manifest, redo, home: tmp), redo)
    XCTAssertEqual(runs().count, 7); XCTAssertTrue(runs().last!.contains("crew@agents=28,items=100"))
  }

  func testAKnobAxisAndTwoFixtureAxes() throws {
    let o = options(["agents=4,8,16", "reel.slide=ca,clip"], reps: 1)
    let d = try r.run(try r.plan(exe: Self.script, manifest: manifest, o, home: tmp), o)
    XCTAssertTrue(runs().filter { $0.contains("knobs=reel.slide=clip") }.count == 3)
    let lines = d.fits.filter { $0.model == "linear" && $0.axis == "agents" }
    XCTAssertEqual(lines.count, 2)                                          // one per knob setting
    XCTAssertEqual(lines.first { $0.at?["reel.slide"] == "clip" }!.intercept - lines.first { $0.at?["reel.slide"] == "ca" }!.intercept, 3, accuracy: 0.05)
    XCTAssertEqual(d.fit?.axis, "agents")                                    // the knob isn't numeric: no plane
  }

  func testBusyPointsAreMarkedAndTheBudgetStops() throws {
    r.env["FAKE_BUSY_AGENTS"] = "16"
    var o = options(["agents=4..28/12"], reps: 1)
    let d = try r.run(try r.plan(exe: Self.script, manifest: manifest, o, home: tmp), o)
    XCTAssertEqual(d.points.first { $0.values["agents"] == "16" }?.busy, true)
    XCTAssertTrue(Sweep.text(d).contains("busy machine at 1 point(s): agents=16"))
    o.out = tmp.appendingPathComponent("budget").path; o.budgetMin = 0.0001
    let b = try r.run(try r.plan(exe: Self.script, manifest: manifest, o, home: tmp), o)
    XCTAssertFalse(b.complete); XCTAssertTrue(b.notes.first?.contains("budget") == true, "\(b.notes)")
  }

  func testTheLockWaitsForItsHolder() throws {
    let lock = tmp.appendingPathComponent("window.lock").path
    try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
    try "another agent\n".write(toFile: lock + "/owner", atomically: true, encoding: .utf8)
    var o = options(["agents=4,8"], reps: 1); o.lock = lock
    var said: [String] = []
    r.log = { said.append($0) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? FileManager.default.removeItem(atPath: lock) }
    let d = try r.run(try r.plan(exe: Self.script, manifest: manifest, o, home: tmp), o)
    XCTAssertTrue(d.complete)
    XCTAssertTrue(said.contains { $0.contains("held by another agent") }, "\(said)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
  }
}

#if os(macOS)
import XCTest
import CoreGraphics
@testable import PerfLoopHost
import PerfLoopKit
import PerfLoopProbe

/// PerfLoopHost without a window: the arithmetic from a rep's raw timeline to the result the runner reads, the
/// headless verbs of the command line, and the snapshot pixel diff.
@MainActor final class HostTests: XCTestCase {
  // MARK: result arithmetic

  /// 120 Hz ticks with one held frame: one late interval, its hitch time, the ratio per second.
  func testFramesAndHitchTime() {
    var xs = [Double](repeating: 1000 / 120, count: 59)
    xs.append(1000 / 120 * 4)   // one frame held for three more vsyncs
    let f = FrameStats(intervalsMs: xs, nominalHz: 120)
    XCTAssertEqual(f.steadyHz, 120)
    XCTAssertEqual(f.late, 1)
    XCTAssertEqual(f.hitchTimeMs, 25, accuracy: 0.01)
    XCTAssertEqual(f.hitchTimeRatioMsPerS, Stats.round(25 / (xs.reduce(0, +)) * 1000, 2))
    // A panel idling at 60 Hz is not late every other frame.
    XCTAssertEqual(FrameStats(intervalsMs: [Double](repeating: 1000 / 60, count: 30), nominalHz: 120).late, 0)
  }

  func timeline() -> Timeline {
    var t = Timeline(nominalHz: 120)
    t.ticks = stride(from: 0.0, through: 400, by: 1000 / 120).map { $0 }
    t.stretches = [StretchSample(id: 1, atMs: 5, durationMs: 3, cpuMs: 2.5),        // set-up
                   StretchSample(id: 2, atMs: 99, durationMs: 40, cpuMs: 38),       // step 1's action: opened before it
                   StretchSample(id: 3, atMs: 205, durationMs: 12, cpuMs: 11),
                   StretchSample(id: 4, atMs: 360, durationMs: 1, cpuMs: 0.5)]
    t.bodies = [BodySample(atMs: 101, view: "Row", id: "1"), BodySample(atMs: 102, view: "Row", id: "2"), BodySample(atMs: 210, view: "Row", id: "1"), BodySample(atMs: 6, view: "Root")]
    return t
  }

  func testStepsAndRep() {
    let t = timeline()
    let s1 = t.step(name: "select#0", at: 100, end: 200, latencyMs: nil, settleMs: 39, settled: true, cpuMs: 38.2, instructions: 1_000_000)
    let s2 = t.step(name: "select#1", at: 200, end: 300, latencyMs: nil, settleMs: 17, settled: true, cpuMs: 11.8, instructions: 3_000_000)
    XCTAssertEqual(s1.mainThread.stretches, 1, "the stretch the action ran in opened 1 ms before the step")
    XCTAssertEqual(s1.mainThread.longestMs, 40)
    XCTAssertEqual(s1.bodies, ["Row": 2])
    XCTAssertEqual(s2.bodies, ["Row": 1])
    let rep = t.rep(index: 0, steps: [s1, s2], checks: [CheckResult(name: "landed", pass: true, detail: "")], guards: nil,
                    window: WindowState(appActive: true, keyWindow: true, visible: true, occluded: false, frame: [0, 0, 900, 700], backingScale: 2))
    XCTAssertEqual(rep.cpuMsPerStep, 25)
    XCTAssertEqual(rep.instructionsPerStep, 2_000_000)
    XCTAssertEqual(rep.worstStretches.first?.step, "select#0")
    XCTAssertEqual(rep.worstStretches.first?.bodies, ["Row": 2])
    XCTAssertFalse(rep.worstStretches.contains { $0.atMs == 5 }, "set-up is not inside the steps")
    XCTAssertEqual(Timeline.label(at: 360, dur: 1, steps: [s1, s2]), "after select#1")
  }

  /// What the host prints, read back the way the runner reads any adapter's result.
  func testResultReadsBackThroughReadings() throws {
    let t = timeline()
    let s1 = t.step(name: "a", at: 100, end: 200, latencyMs: 30, settleMs: 39, settled: true, cpuMs: 40, instructions: nil)
    let s2 = t.step(name: "b", at: 200, end: 300, latencyMs: 50, settleMs: 17, settled: true, cpuMs: 20, instructions: nil)
    let w = WindowState(appActive: true, keyWindow: false, visible: true, occluded: false, frame: [], backingScale: 2)
    let rep = t.rep(index: 0, steps: [s1, s2], checks: [CheckResult(name: "landed", pass: false, detail: "off by one")],
                    guards: [GuardResult(name: "snapshot-diff", pass: true, detail: "captured", artifacts: ["/x/a.png", "/x/a.later.png"])], window: w)
    let summary = ResultSummary(reps: [rep], metric: "latencyMs")
    XCTAssertEqual(summary.objective.value, Stats.median([30, 50]))
    XCTAssertEqual(summary.checksFailed, ["landed"])
    let b = Build(hash: "sha256:00", commit: "abc1234", dirty: false, configuration: "release", stamp: true)
    let r = HostResult(tool: ToolInfo(name: "x-bench", version: "1", configuration: "release", commit: "abc1234", build: b), app: "x", adapter: "x-bench",
                       scenario: "select", fixture: "rows500", params: ["steps": .string("2"), "knobs": .object([:])], startedAt: Clock.now(), reps: [rep], summary: summary,
                       verdict: "fail", exitCode: 3, notes: [])
    let v = try PLJSON.decode(JSONValue.self, from: Data(PLJSON.encode(r).utf8))
    XCTAssertEqual(v["schema"]?.string, "perfloop.result/2")
    let cpu = Readings.sides(run: v, metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(cpu.count, 1)
    XCTAssertEqual(cpu[0].objective, 30)
    XCTAssertEqual(cpu[0].checksFailed, ["landed"])
    XCTAssertEqual(cpu[0].trustworthy, false, "not the key window: untrusted")
    XCTAssertEqual(cpu[0].guards?.first?.name, "snapshot-diff")
    XCTAssertNotNil(cpu[0].hitchTimeRatioMsPerS); XCTAssertEqual(cpu[0].longestStretchMs, 40)
    XCTAssertEqual(Readings.sides(run: v, metric: "latencyMs")[0].objective, Stats.median([30, 50]))
  }

  // MARK: the command line, headless

  enum Pick: String, KnobValue, CaseIterable { case sort, index
    init?(knobText s: String) { self.init(rawValue: s) }
    var knobText: String { rawValue }
    static var knobType: String { "choice" }
  }
  static let pick = Knob("test.rank", default: Pick.sort, choices: Pick.allCases, summary: "how a row finds its rank")

  func bench() -> Bench {
    let b = Bench(app: "testapp", stamp: "commit=abc1234\ndirty=0\nsourceHash=sha256:11\ntoolchain=Xcode 27.1 (27A1)\nbuiltAt=2026-11-04T10:00:00Z")
    b.fixture("rows500", summary: "500 rows", params: ["rows": "500"], parametric: ["rows": 10...5000])
    b.fixture("rows50", params: ["rows": "50"])
    b.knobs { [Self.pick] }
    b.scenario("select", summary: "select rows", guards: ["checks", "snapshot-diff"], guardParams: ["snapshot-diff.tolerance": 0.01], params: ["steps": "8"],
               secondFixture: "rows50") { _ in }
    b.scenario("open", summary: "open the list", kind: .latency, latencyBudgetMs: 100) { _ in }
    return b
  }

  func testListCarriesTheStampAndTheHash() throws {
    let (code, out) = bench().handle(["list", "--json"])
    XCTAssertEqual(code, 0)
    let v = try PLJSON.decode(JSONValue.self, from: Data(out.utf8))
    let b = try XCTUnwrap(Build(json: v["tool"]?["build"]))
    XCTAssertTrue(b.stamp)
    XCTAssertEqual(b.commit, "abc1234")
    XCTAssertFalse(b.dirty)
    XCTAssertEqual(b.toolchain, "Xcode 27.1 (27A1)")
    XCTAssertEqual(b.hash, FileHash.sha256(file: URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath().path))
    XCTAssertEqual(v["scenarios"]?.array?.count, 2)
    XCTAssertFalse(Bench.build(stamp: nil, hash: nil).stamp, "no stamp: store add refuses it")
    XCTAssertTrue(Bench.build(stamp: "commit=\ndirty=1\n", hash: nil).dirty)
  }

  func testDescribeIsAManifestTheRunnerUnderstands() throws {
    let (code, out) = bench().handle(["describe", "--json"])
    XCTAssertEqual(code, 0)
    let m = try PLJSON.decode(Manifest.self, from: Data(out.utf8))
    XCTAssertEqual(m.schema, "perfloop.manifest/1")
    XCTAssertEqual(m.app, "testapp"); XCTAssertEqual(m.adapter, "testapp-bench")
    XCTAssertEqual(m.scenario("select")?.objective, "mainThreadCpuMsPerStep")
    XCTAssertEqual(m.scenario("select")?.guards, ["checks", "snapshot-diff"])
    XCTAssertEqual(m.scenario("select")?.guardParams?["snapshot-diff.tolerance"]?.double, 0.01)
    XCTAssertEqual(m.scenario("select")?.secondFixture, "rows50")
    XCTAssertEqual(m.scenario("open")?.objective, "latencyMs")
    XCTAssertEqual(m.fixtureNames, ["rows500", "rows50"])
    XCTAssertEqual(m.knobs.first?.name, "test.rank"); XCTAssertEqual(m.knobs.first?.choices, ["sort", "index"])
    XCTAssertEqual(m.defaultFixture, "rows500")
    XCTAssertFalse(m.has(verb: "ab")); XCTAssertTrue(m.has(verb: "snapdiff"))
    XCTAssertTrue(m.has(verb: "profile")); XCTAssertTrue(m.has(verb: "diff"))
    XCTAssertEqual(m.defaultVia, "run", "no ab: the runner measures pairs through run")
  }

  /// `diff A B` on two profile documents, headless: per step, what shrank, provenance from their builds.
  func testDiffOfTwoProfilesHeadless() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-hostdiff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func profile(_ name: String, sortMs: Int, hash: String) throws -> String {
      var p = ProfileDoc(template: "Time Profiler", trace: nil, scenario: "select", fixture: "rows500", process: "TestBench", durationS: 1)
      p.build = Build(hash: hash, commit: "abc1234", dirty: false, stamp: true)
      p.steps = (0..<4).map { StepInterval(name: "select#\($0)", startNs: $0 * 100, endNs: $0 * 100 + 50, source: "signpost") }
      p.sampleIntervalMs = 1
      let sort = CallTree(n: "ListModel.rankBySorting", v: sortMs, o: true, c: [CallTree(n: "-[NSString localizedStandardCompare:]", v: sortMs)])
      p.treeInSteps = CallTree(n: "main thread", v: sortMs + 40, c: [CallTree(n: "main", v: sortMs + 40, o: true, c: [sort, CallTree(n: "CA::Transaction::commit", v: 40)])])
      p.tree = p.treeInSteps
      let path = dir.appendingPathComponent("\(name).json").path
      try PLJSON.encode(p).write(toFile: path, atomically: true, encoding: .utf8)
      return path
    }
    let a = try profile("a", sortMs: 360, hash: "sha256:aa"), b = try profile("b", sortMs: 8, hash: "sha256:bb")
    let (code, out) = bench().handle(["diff", a, b, "--json"])
    XCTAssertEqual(code, 0, out)
    let d = try PLJSON.decode(DiffResult.self, from: Data(out.utf8))
    XCTAssertEqual(d.a.msPerStep, 100); XCTAssertEqual(d.b.msPerStep, 12); XCTAssertEqual(d.a.stepSource, "signpost")
    XCTAssertEqual(d.gains.first?.symbol, "ListModel.rankBySorting"); XCTAssertEqual(d.gains.first?.d, -88)
    XCTAssertTrue(bench().handle(["diff", a, b]).1.contains("shrank in b"))
    // Against a named champion build, a side of another build is stale: refused (6) unless allowed.
    XCTAssertEqual(bench().handle(["diff", a, b, "--champion", "sha256:bb"]).0, 6)
    XCTAssertEqual(bench().handle(["diff", a, b, "--champion", "sha256:bb", "--allow-stale"]).0, 0)
    XCTAssertEqual(bench().handle(["diff", a]).0, 1)
  }

  func testUnknownVerbIsAUsageError() {
    let (code, out) = bench().handle(["frobnicate"])
    XCTAssertEqual(code, 1)
    XCTAssertTrue(out.contains("unknown command 'frobnicate'"))
    XCTAssertEqual(bench().handle(["snapdiff", "only-one.png"]).0, 1)
  }

  func testParametricFixtures() throws {
    let b = bench()
    XCTAssertEqual(try b.resolveFixture("rows500@rows=2000").params["rows"], "2000")
    XCTAssertEqual(try b.resolveFixture("rows500@rows=2000").name, "rows500@rows=2000")
    XCTAssertEqual(try b.resolveFixture(nil).name, "rows500")
    XCTAssertThrowsError(try b.resolveFixture("rows500@rows=9000"))
    XCTAssertThrowsError(try b.resolveFixture("rows500@cols=3"))
    XCTAssertThrowsError(try b.resolveFixture("nope"))
  }

  // MARK: snapshots

  func picture(_ w: Int, _ h: Int, _ paint: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Snapshot.Pixels {
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { let (r, g, b) = paint(x, y); let k = (y * w + x) * 4; bytes[k] = r; bytes[k + 1] = g; bytes[k + 2] = b } }
    return Snapshot.Pixels(width: w, height: h, bytes: bytes)
  }

  func testPixelDiffMasksWhatMovesByItself() {
    let a = picture(100, 100) { _, _ in (240, 240, 240) }
    XCTAssertEqual(Snapshot.compare(a, a).share, 0)
    // B blanks a 10×100 band: 10 % of the pixels.
    let b = picture(100, 100) { x, _ in x < 10 ? (0, 0, 0) : (240, 240, 240) }
    XCTAssertEqual(Snapshot.compare(a, b).share, 0.1, accuracy: 1e-9)
    // A caret blinking in a 2×100 band of A's own later picture is left out.
    let aLater = picture(100, 100) { x, _ in x >= 98 ? (0, 0, 0) : (240, 240, 240) }
    let c = Snapshot.compare(a, b, aLater: aLater)
    XCTAssertEqual(c.moving, 200); XCTAssertEqual(c.differing, 1000)
    XCTAssertTrue(Snapshot.compare(a, picture(50, 100) { _, _ in (240, 240, 240) }).sizeMismatch)
  }

  func testSnapdiffVerbOnFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-host-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = picture(64, 64) { _, _ in (200, 200, 200) }, b = picture(64, 64) { x, y in x < 8 && y < 8 ? (0, 0, 0) : (200, 200, 200) }
    let pa = dir.appendingPathComponent("a.png").path, pb = dir.appendingPathComponent("b.png").path
    try XCTUnwrap(a.png()).write(to: URL(fileURLWithPath: pa)); try XCTUnwrap(b.png()).write(to: URL(fileURLWithPath: pb))
    XCTAssertEqual(Snapshot.Pixels(path: pa)?.bytes, a.bytes, "PNG round trip is lossless")
    let same = bench().handle(["snapdiff", pa, pa, "--json"])
    XCTAssertEqual(same.0, 0)
    let diffOut = dir.appendingPathComponent("d.png").path
    let (code, out) = bench().handle(["snapdiff", pa, pb, "--json", "--diff-out", diffOut])
    XCTAssertEqual(code, 3, "64 of 4096 pixels (1.6 %) is over the default 0.5 %")
    let g = try XCTUnwrap(GuardResult(json: try PLJSON.decode(JSONValue.self, from: Data(out.utf8))["guard"]))
    XCTAssertFalse(g.pass); XCTAssertEqual(g.review, true); XCTAssertEqual(g.value ?? 0, 64.0 / 4096, accuracy: 1e-4)
    XCTAssertTrue(FileManager.default.fileExists(atPath: diffOut))
    XCTAssertEqual(bench().handle(["snapdiff", pa, pb, "--guard-param", "snapshot-diff.tolerance=0.02"]).0, 0)
  }
}
#endif

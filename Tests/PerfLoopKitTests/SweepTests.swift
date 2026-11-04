import XCTest
@testable import PerfLoopKit

/// Sweeps (C8): the grid syntax, the order, the fits and the sentence `explain` prints.
final class SweepTests: XCTestCase {
  func testAxisSyntax() throws {
    XCTAssertEqual(try SweepAxis.parse("agents=4..64/12").values, ["4", "16", "28", "40", "52", "64"])
    XCTAssertEqual(try SweepAxis.parse("agents=4..64/4").values.count, 16)
    XCTAssertEqual(try SweepAxis.parse("items=50..60").values.count, 11)
    XCTAssertEqual(try SweepAxis.parse("x=0.5..1.5/0.5").values, ["0.5", "1.0", "1.5"])
    XCTAssertEqual(try SweepAxis.parse("reel.slide=ca,clip").values, ["ca", "clip"])
    let one = try SweepAxis.parse("steps=8"); XCTAssertEqual(one.name, "steps"); XCTAssertEqual(one.values, ["8"])
    for bad in ["agents", "agents=", "agents=64..4", "agents=4..64/0", "agents=a..b", "=4"] { XCTAssertThrowsError(try SweepAxis.parse(bad), bad) }
    XCTAssertTrue(SweepAxis(name: "a", role: "fixture", values: ["4", "8"]).numeric)
    XCTAssertFalse(SweepAxis(name: "k", role: "knob", values: ["ca", "clip"]).numeric)
  }

  func testGridKeysAndFixtureNames() {
    let axes = [SweepAxis(name: "agents", role: "fixture", values: ["4", "8"]), SweepAxis(name: "items", role: "fixture", values: ["50", "100", "150"])]
    let g = Sweep.grid(axes)
    XCTAssertEqual(g.count, 6)
    XCTAssertEqual(g[0], ["agents": "4", "items": "50"]); XCTAssertEqual(g[5], ["agents": "8", "items": "150"])
    XCTAssertEqual(Sweep.key(g[1], axes: axes), "agents=4,items=100")
    XCTAssertEqual(Sweep.fixtureName("crew", ["items": "100", "agents": "24"]), "crew@agents=24,items=100")
    XCTAssertEqual(Sweep.fixtureName("crew@projects=2,agents=8", ["agents": "24"]), "crew@agents=24,projects=2")
    XCTAssertEqual(Sweep.fixtureName("crew17", [:]), "crew17")
    XCTAssertEqual(Sweep.fileName("reel.slide=a/b,x=1"), "reel.slide=a_b,x=1")
  }

  func testShuffledOrderIsAFixedPermutation() {
    let axes = [SweepAxis(name: "agents", role: "fixture", values: (1...16).map(String.init))]
    let g = Sweep.grid(axes)
    let a = Sweep.order(g, "shuffle", seed: "s"), b = Sweep.order(g, "shuffle", seed: "s")
    XCTAssertEqual(a, b)                                                    // a resumed sweep keeps its order
    XCTAssertNotEqual(a, g)                                                 // not ascending: drift doesn't become slope
    XCTAssertEqual(Set(a.map { $0["agents"]! }), Set(g.map { $0["agents"]! }))
    XCTAssertEqual(Sweep.order(g, "grid", seed: "s"), g)
  }

  func testLinearFitRecoversSlopeAndReportsResiduals() throws {
    let x: [Double] = [4, 16, 28, 40, 52, 64]
    let exact = try XCTUnwrap(Sweep.linear(x, x.map { 2.3 + 0.92 * $0 }, axis: "agents", unit: "ms per step per agent"))
    XCTAssertEqual(exact.slope, 0.92, accuracy: 1e-9); XCTAssertEqual(exact.intercept, 2.3, accuracy: 1e-9); XCTAssertEqual(exact.r2, 1)
    XCTAssertEqual(exact.residuals.count, 6); XCTAssertTrue(exact.residuals.allSatisfy { abs($0) < 1e-6 })
    let noise: [Double] = [0.8, -1.1, 0.4, 1.3, -0.9, -0.5]
    let noisy = try XCTUnwrap(Sweep.linear(x, zip(x, noise).map { 2.3 + 0.92 * $0 + $1 }, axis: "agents", unit: "u"))
    XCTAssertEqual(noisy.slope, 0.92, accuracy: 0.05); XCTAssertLessThan(noisy.r2, 1); XCTAssertGreaterThan(noisy.r2, 0.98)
    XCTAssertEqual(noisy.residuals.reduce(0, +), 0, accuracy: 1e-3)        // least squares with an intercept: residuals sum to 0
    XCTAssertNil(Sweep.linear([4, 4, 4], [1, 2, 3], axis: "a", unit: "u"))  // one distinct x: no line
  }

  func testQuadraticSaysWhenTheCostCurves() throws {
    let x: [Double] = [4, 16, 28, 40, 52, 64]
    let y = x.map { 1 + 0.1 * $0 + 0.05 * $0 * $0 }
    let l = try XCTUnwrap(Sweep.linear(x, y, axis: "agents", unit: "u")), q = try XCTUnwrap(Sweep.quadratic(x, y, axis: "agents", unit: "u"))
    XCTAssertEqual(q.quadratic!, 0.05, accuracy: 1e-6); XCTAssertEqual(q.slope, 0.1, accuracy: 1e-4)
    XCTAssertTrue(Sweep.curves(linear: l, quadratic: q))
    let straight = x.map { 2 + 0.9 * $0 + [0.3, -0.2, 0.1, -0.3, 0.2, -0.1][x.firstIndex(of: $0)!] }
    XCTAssertFalse(Sweep.curves(linear: Sweep.linear(x, straight, axis: "a", unit: "u")!, quadratic: Sweep.quadratic(x, straight, axis: "a", unit: "u")!))
    XCTAssertNil(Sweep.quadratic([1, 2, 3], [1, 4, 9], axis: "a", unit: "u"))   // three points fit any parabola
  }

  func testPlaneThroughTwoAxes() throws {
    var points: [SweepPoint] = []
    for a in [4.0, 16, 28, 40] { for i in [50.0, 200, 400] {
      var p = SweepPoint(values: ["agents": String(Int(a)), "items": String(Int(i))]); p.objective = 1.5 + 0.9 * a + 0.02 * i; points.append(p)
    } }
    let axes = [SweepAxis(name: "agents", role: "fixture", values: ["4", "16", "28", "40"]), SweepAxis(name: "items", role: "fixture", values: ["50", "200", "400"])]
    let (head, all) = Sweep.fits(points, axes: axes, objective: "mainThreadCpuMsPerStep")
    let h = try XCTUnwrap(head)
    XCTAssertEqual(h.model, "plane"); XCTAssertEqual(h.coefficients?["agents"] ?? 0, 0.9, accuracy: 1e-6); XCTAssertEqual(h.coefficients?["items"] ?? 0, 0.02, accuracy: 1e-6)
    XCTAssertEqual(all.filter { $0.model == "linear" && $0.axis == "agents" }.count, 3)     // one line per items slice
    XCTAssertEqual(all.filter { $0.model == "linear" && $0.axis == "items" }.count, 4)
    XCTAssertTrue(Sweep.sentence(h, objective: "mainThreadCpuMsPerStep").contains("0.9 ms per agent + 0.02 ms per item"))
  }

  func testSentenceAndText() throws {
    let f = SweepFit(model: "linear", axis: "agents", n: 6, slope: 0.9, intercept: 2.3, r2: 0.981, residuals: [], rmse: 0.4, unit: "ms per step per agent")
    XCTAssertEqual(Sweep.sentence(f, objective: "mainThreadCpuMsPerStep"), "ms/step grows 0.9 ms per agent (r² 0.98)")
    var g = f; g.slope = -1_200_000; g.axis = "build.perFrame"
    XCTAssertEqual(Sweep.sentence(g, objective: "instructionsPerStep"), "instructions/step falls 1.2 M instructions per perFrame (r² 0.98)")

    let axes = [SweepAxis(name: "agents", role: "fixture", values: ["4", "16", "28", "40"])]
    var pts = axes[0].values.map { v -> SweepPoint in var p = SweepPoint(values: ["agents": v]); p.objective = 2 + 0.9 * Double(v)!; p.dist = Dist([p.objective!]); p.guardsPassed = true; return p }
    pts[2].busy = true
    pts.append(SweepPoint(values: ["agents": "52"]))
    var d = SweepDoc(scenario: "step", fixture: "crew", objective: "mainThreadCpuMsPerStep", build: nil, axis: axes, reps: 2, points: pts)
    d.axis[0].values.append("52")
    (d.fit, d.fits) = Sweep.fits(d.points, axes: d.axis, objective: d.objective)
    let t = Sweep.text(d)
    XCTAssertTrue(t.contains("fit: ms/step grows 0.9 ms per agent (r² 1.0)"), t)
    XCTAssertTrue(t.contains("busy machine at 1 point(s): agents=28"), t)
    XCTAssertTrue(t.contains("missing 1 point(s)"), t)
  }

  func testSweepDocRoundTripsAndPointsReadAsTheSchemaShowsThem() throws {
    var p = SweepPoint(values: ["agents": "4", "reel.slide": "clip"]); p.objective = 6.1; p.dist = Dist([6.1, 6.3]); p.hitchTimeRatioMsPerS = 0; p.guardsPassed = true; p.reps = 2
    var d = SweepDoc(scenario: "step", fixture: "crew", objective: "mainThreadCpuMsPerStep", build: Build(hash: "sha256:ab", commit: "abc", dirty: false, stamp: true),
                     axis: [SweepAxis(name: "agents", role: "fixture", values: ["4", "8"])], reps: 2, points: [p])
    d.fit = Sweep.linear([4, 8], [6.1, 9.7], axis: "agents", unit: "u")
    let text = PLJSON.encode(d)
    XCTAssertTrue(text.contains(#""schema" : "perfloop.sweep/1""#))
    XCTAssertTrue(text.contains(#""agents" : 4"#))                          // flat, as SCHEMAS.md §7, and numeric
    XCTAssertEqual(try PLJSON.decode(SweepDoc.self, from: Data(text.utf8)), d)
    let schemaShaped = #"{ "agents": 4, "objective": 6.1, "dist": { "n": 1, "min": 6.1, "median": 6.1, "p95": 6.1, "max": 6.1, "mad": 0 }, "hitchTimeRatioMsPerS": 0.0, "guardsPassed": true }"#
    let q = try PLJSON.decode(SweepPoint.self, from: Data(schemaShaped.utf8))
    XCTAssertEqual(q.values, ["agents": "4"]); XCTAssertEqual(q.objective, 6.1); XCTAssertTrue(q.usable)
  }

  func testEstimate() {
    XCTAssertEqual(Sweep.estimate(points: 6, reps: 2, repS: 7, startupS: 6), 6 * 20)
  }

  /// Where a cost curve crosses a frame: read off inside the measured range, extended past it within 4×, never claimed
  /// beyond; JOURNEY's 3.28 ms per agent from 50 ms at 4 agents is over a 60 Hz frame from the smallest point.
  func testWallsSayWhereTheBudgetIsCrossedAndHowFarThatIsExtrapolated() throws {
    func doc(_ f: (Double) -> Double, _ xs: [Double], objective: String = "mainThreadCpuMsPerStep") throws -> SweepDoc {
      let axes = [SweepAxis(name: "rows", role: "fixture", values: xs.map { String(Int($0)) })]
      let pts = xs.map { x -> SweepPoint in var p = SweepPoint(values: ["rows": String(Int(x))]); p.objective = f(x); return p }
      var d = SweepDoc(scenario: "select", fixture: "rows", objective: objective, build: nil, axis: axes, reps: 1, points: pts)
      (d.fit, d.fits) = Sweep.fits(pts, axes: axes, objective: objective)
      return d
    }
    // 2 ms + 0.01 ms per row: 120 Hz (8.33 ms) at ~633 rows, 60 Hz (16.67 ms) at ~1467.
    let inside = Sweep.walls(try doc({ 2 + 0.01 * $0 }, [100, 400, 700, 1000]))
    XCTAssertEqual(inside.map(\.kind), ["inside", "extrapolated"])
    XCTAssertEqual(inside[0].crossesAt ?? 0, 633.3, accuracy: 0.2); XCTAssertEqual(inside[1].factor ?? 0, 1.47, accuracy: 0.01)
    XCTAssertTrue(Sweep.wallSentence(inside[1], objective: "mainThreadCpuMsPerStep").contains("extrapolated 1.47× past the largest measured"))
    // Far away: not claimed.
    let far = Sweep.walls(try doc({ 1 + 0.0001 * $0 }, [100, 200, 300, 400]))
    XCTAssertEqual(far.map(\.kind), ["beyond", "beyond"]); XCTAssertNil(far[0].crossesAt)
    // Already over, flat, and the budget the caller names.
    XCTAssertEqual(Sweep.walls(try doc({ 50 + 3.28 * $0 }, [4, 16, 28, 40])).map(\.kind), ["already", "already"])
    XCTAssertEqual(Sweep.walls(try doc({ 5 - 0.001 * $0 }, [100, 200, 300])).map(\.kind), ["never", "never"])
    let mine = Sweep.walls(try doc({ 2 + 0.01 * $0 }, [100, 400, 700, 1000]), budgets: [(5, "5 ms")])
    XCTAssertEqual(mine.count, 1); XCTAssertEqual(mine[0].crossesAt ?? 0, 300, accuracy: 0.5)
    XCTAssertTrue(Sweep.walls(try doc({ 2 + 0.01 * $0 }, [1, 2, 3], objective: "instructionsPerStep")).isEmpty, "no default budget for instructions")
    let text = Sweep.text(try doc({ 2 + 0.01 * $0 }, [100, 400, 700, 1000]))
    XCTAssertTrue(text.contains("wall: ms/step reaches 8.33 ms (a 120 Hz frame) at rows ≈ 633, inside the measured range"), text)
  }
}

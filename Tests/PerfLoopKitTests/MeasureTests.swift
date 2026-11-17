import XCTest
@testable import PerfLoopKit

/// A one-build measurement's numbers come from trusted reps only, its text never shows an untrusted number as one to
/// quote, a baseline comparison is information with the reference taken out, and a scenario's own fixture is read
/// from the manifest and checked.
final class MeasureTests: XCTestCase {
  func rep(_ i: Int, _ v: Double, quiet: Bool? = true, key: Bool = true, exit: Int = 0, fixture: String? = "crew17") -> MeasureRep {
    var s = Side(objective: v, hitch: 1, longest: 20); s.quiet = quiet; s.exit = exit; s.fixture = fixture
    s.trustworthy = key; s.windowFailed = key ? nil : ["keyWindow"]
    return MeasureRep(index: i, result: nil, side: s)
  }

  func testOnlyTrustedRepsMakeTheNumbers() {
    var busy = rep(1, 99, quiet: false); busy.side.busyPct = 97.5; busy.side.busy = ["swift-build"]
    busy = MeasureRep(index: 1, result: nil, side: busy.side)
    let s = Measure.summary([rep(0, 10), busy, rep(2, 12), rep(3, 50, exit: 5)])
    XCTAssertEqual(s.trusted, 2); XCTAssertEqual(s.ran, 4)
    XCTAssertEqual(s.values, [10, 12]); XCTAssertEqual(s.median, Stats.median([10, 12])); XCTAssertEqual(s.max, 12)
    XCTAssertEqual(s.untrusted, "2/4 reps untrusted: not quiet ×1 (busy up to 97.5 %: swift-build); exit 5 (the bench's own untrusted) ×1")
    XCTAssertNil(s.deterministic)
  }

  func testNothingTrustedPrintsNoNumber() {
    var m = ScenarioRun(id: "m0001", kind: "run", target: "champion", build: Build(hash: "sha256:ab", commit: "c0ffee1", dirty: false, stamp: true), scenario: "step", fixture: "crew17", metric: "latencyMs")
    m.reps = [rep(0, 41.2, quiet: false), rep(1, 40.9, quiet: false)]
    m.summary = Measure.summary(m.reps)
    let t = Measure.text(m)
    XCTAssertTrue(t.contains("latencyMs: UNTRUSTED: 0/2 reps trusted (2/2 reps untrusted: not quiet ×2): no number to quote"), t)
    XCTAssertFalse(t.contains("median"), t)
    XCTAssertTrue(t.contains("rep 1: UNTRUSTED (not quiet); its 41.2 is not a number to quote"), t)
  }

  func testTheSameWrongWindowEveryTimeIsDeterministic() {
    let reps = [rep(0, 10, key: false), rep(1, 11, key: false)]
    XCTAssertEqual(Measure.deterministic(reps), "deterministic: window keyWindow=false in all 2 untrusted reps: a rerun won't change it")
    XCTAssertTrue(Measure.worthRedoing(reps[0], after: []))
    XCTAssertFalse(Measure.worthRedoing(reps[1], after: [reps[0]]))
    XCTAssertTrue(Measure.worthRedoing(rep(2, 10, quiet: false), after: reps), "a busy Mac may be quiet next time")
  }

  func testAFixtureThatDidntRunIsCaught() {
    XCTAssertNil(Measure.fixtureMismatch(rep(0, 1).side, asked: "crew17"))
    XCTAssertNil(Measure.fixtureMismatch(rep(0, 1, fixture: "crew17").side, asked: "crew17@agents=4"))
    XCTAssertNil(Measure.fixtureMismatch(rep(0, 1, fixture: nil).side, asked: "search"), "an adapter that doesn't say")
    XCTAssertEqual(Measure.fixtureMismatch(rep(0, 1).side, asked: "search")?.hasPrefix("ran fixture crew17, asked for search"), true)
    let failed = MeasureRep(index: 0, result: nil, side: rep(0, 1).side, failure: Measure.fixtureMismatch(rep(0, 1).side, asked: "search"))
    XCTAssertFalse(failed.trusted); XCTAssertFalse(Measure.worthRedoing(failed, after: []))
  }

  func testABaselineComparisonTakesTheReferenceOut() {
    var b = BaselineRecord(scenario: "toggle", fixture: "search", metric: "latencyMs", measurement: "m0001", build: Build(hash: "sha256:01", commit: "a", dirty: false, stamp: true),
                           trusted: 5, reps: 5, median: 40, min: 36, max: 44)
    b.referenceScenario = "select"; b.referenceMedian = 20
    var s = MeasureSummary(); s.median = 50
    var r = MeasureReference(scenario: "select", fixture: "rows", experiment: "0003", build: b.build, metric: "latencyMs")
    r.summary.median = 25                              // the whole Mac ran 25 % slower
    let c = try! XCTUnwrap(Measure.compare(s, fixture: "search", reference: r, with: b))
    XCTAssertEqual(c.deltaPct, 25); XCTAssertFalse(c.inRange); XCTAssertTrue(c.sameFixture)
    XCTAssertEqual(c.normalisedDeltaPct, 0, "the same, once the Mac's own slowdown is taken out")
    XCTAssertNil(Measure.compare(MeasureSummary(), fixture: "search", reference: nil, with: b), "nothing trusted: nothing to compare")
    XCTAssertFalse(Measure.compare(s, fixture: "crew17", reference: nil, with: b)!.sameFixture)
  }

  func testAScenariosOwnFixture() throws {
    let text = #"""
    { "schema": "perfloop.manifest/1", "protocol": 1, "app": "a", "adapter": "b", "defaultFixture": "crew17",
      "scenarios": [ { "name": "palette-open", "kind": "latency", "fixture": "search" }, { "name": "step" } ],
      "fixtures": [ { "name": "crew17", "parametric": { "agents": [1, 64] } }, { "name": "search" } ] }
    """#
    let m = try PLJSON.decode(Manifest.self, from: Data(text.utf8))
    XCTAssertEqual(m.scenario("palette-open")?.fixture, "search")
    XCTAssertEqual(m.fixture(for: "palette-open"), "search"); XCTAssertEqual(m.fixture(for: "step"), "crew17"); XCTAssertEqual(m.fixture(for: nil), "crew17")
    XCTAssertNil(m.unknownFixture("crew17@agents=3")); XCTAssertNil(m.unknownFixture("file:/tmp/x.json"), "the adapter's own form")
    XCTAssertEqual(m.unknownFixture("crew71", whose: "the champion's manifest"), "unknown fixture 'crew71'; the champion's manifest has crew17, search")
    // A scenario's fixture is part of what judges a build; a manifest without one keeps the contract it had.
    var other = m; other.scenarios[0].fixture = "crew17"
    XCTAssertNotEqual(m.contract, other.contract)
    other.scenarios[0].fixture = nil
    XCTAssertFalse(other.contract.contains("fixture="))
    let derived = try XCTUnwrap(Manifest.derived(fromList: .object(["scenarios": .array([.object(["name": .string("x"), "fixture": .string("search")])])])))
    XCTAssertEqual(derived.scenario("x")?.fixture, "search")
  }
}

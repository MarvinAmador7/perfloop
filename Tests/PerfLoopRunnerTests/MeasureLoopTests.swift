import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// `perfloop run` and `perfloop baseline` (F5) and per-scenario fixtures (F8), against the fake adapter: a scenario only
/// the candidate has is measured through the runner and the ledger, untrusted reps are named and never quoted, a
/// baseline is compared with once the champion has its scenario, `--reference` interleaves a champion scenario, and a
/// fixture is the scenario's own, validated, and checked against the one that ran.
final class MeasureLoopTests: FakeBenchCase {
  override func tearDownWithError() throws { unsetenv("FAKE_ENV_QUIET"); try super.tearDownWithError() }

  func runs() -> [String] { adapterCalls("run").map { $0.split(separator: " ").prefix(3).joined(separator: " ") } }
  func options(_ target: String, _ scenario: String?, kind: String = "run", reps: Int = 2) -> Loop.MeasureOptions {
    var o = Loop.MeasureOptions(target: target, kind: kind); o.scenario = scenario; o.reps = reps
    return o
  }

  func testAFeaturesOwnScenarioIsMeasuredNotRefused() throws {
    try baseline()
    let cand = try bench("cand", ["EXTRA": "toggle", "CPU": "20"])
    var n = Loop.NewOptions(hypothesis: "a sidebar toggle"); n.bench = cand; n.scenario = "toggle"
    XCTAssertThrowsError(try loop.new(n)) { e in
      let t = "\(e)"
      XCTAssertTrue(t.contains("unknown scenario 'toggle'; the champion's manifest has step, switch"), t)
      XCTAssertTrue(t.contains("perfloop run BUILD --scenario toggle") && t.contains("perfloop baseline toggle --bench PATH"), t)
    }

    let m = try loop.runScenario(options(cand, "toggle", reps: 3))
    XCTAssertEqual(m.fixture, "swarm64", "the scenario's own fixture")
    XCTAssertEqual(m.expectedFixture, "swarm64")
    XCTAssertEqual(m.metric, "latencyMs")
    XCTAssertEqual(runs(), Array(repeating: "run toggle swarm64", count: 3), "one child per rep, through the runner")
    XCTAssertEqual(m.summary.trusted, 3); XCTAssertEqual(m.summary.ran, 3)
    XCTAssertNotNil(m.summary.median)
    XCTAssertEqual(m.reps[0].side.fixture, "swarm64", "what ran is recorded")
    XCTAssertEqual(m.runner?.runner, "local")
    XCTAssertEqual(Loop.exitCode(m), 0)
    XCTAssertTrue(m.next?.contains("perfloop baseline toggle --build") == true, m.next ?? "")
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.measureDir(m.id).appendingPathComponent("run.json").path))
    XCTAssertEqual(try store.measurement("run/m0001"), m)
    XCTAssertTrue(Self.pictures(store.measureDir(m.id)).isEmpty, "the reps' snapshots are cleaned up")

    let l = try XCTUnwrap(store.ledger.entries().last)
    XCTAssertEqual(l.state, "measure"); XCTAssertEqual(l.experiment, "m0001"); XCTAssertEqual(l.objective?.after, m.summary.median)
    XCTAssertTrue(l.note?.hasPrefix("run toggle on swarm64: latencyMs") == true, l.note ?? "")
    XCTAssertTrue(store.experiments().allSatisfy { $0.kind == "baseline" }, "no experiment, no verdict")
    XCTAssertTrue(Stopping.reasons(StopInput(session: store.ledger.currentSession())).isEmpty)
    let text = Measure.text(m)
    XCTAssertTrue(text.contains("run m0001 · toggle on swarm64 (the scenario's own fixture)"), text)
    XCTAssertTrue(text.contains("latencyMs: ") && text.contains("3/3 reps trusted") && text.contains("checks: all passed"), text)
    XCTAssertTrue(text.contains("worst stretch: 40 ms in step#3"), text)
  }

  /// A PerfLoopHost bench's input steps: one rep's lines in the run, its pictures moved into the run's folder (the
  /// other reps' deleted), paths relative to the store.
  func testInputLinesAndOneRepsPicturesAreKept() throws {
    try baseline()
    let cand = try bench("cand", ["EXTRA": "toggle", "INPUT": "1"])
    let m = try loop.runScenario(options(cand, "toggle", reps: 2))
    let i = try XCTUnwrap(m.input)
    XCTAssertEqual(i.rep, 1)
    XCTAssertEqual(i.lines, ["press ⌘K → fired menu 'Search…'; focus: nothing → #palette.field",
                             "close: focus: #palette.field → nothing (the step has no expectFocus: say where the keyboard should land)"])
    XCTAssertEqual(i.pictures[0], ["runs/m0001/input/press-k.after.png", "runs/m0001/input/press-k.diff.png", "runs/m0001/input/press-k.before.png"])
    XCTAssertEqual(i.pictures[1], [])
    for p in i.pictures[0] { XCTAssertTrue(FileManager.default.fileExists(atPath: store.abs(p)), p) }
    let dir = store.measureDir(m.id)
    XCTAssertEqual(Self.pictures(dir).map { $0.deletingLastPathComponent().lastPathComponent }, ["input", "input", "input"], "the other rep's are deleted")
    let text = Measure.text(m)
    XCTAssertTrue(text.contains("input (rep 1):\n  press ⌘K → fired menu 'Search…'; focus: nothing → #palette.field\n    look at: runs/m0001/input/press-k.after.png"), text)
  }

  func testUntrustedRepsAreNamedNeverQuoted() throws {
    try baseline()
    setenv("FAKE_ENV_QUIET", "false", 1)
    let m = try loop.runScenario(options("champion", nil))
    XCTAssertEqual(m.scenario, "step"); XCTAssertEqual(m.fixture, "crew17", "the champion's own scenario and fixture")
    XCTAssertEqual(runs().count, 4, "each untrusted rep redone once")
    XCTAssertEqual(m.summary.trusted, 0); XCTAssertNil(m.summary.median); XCTAssertTrue(m.summary.values.isEmpty)
    XCTAssertEqual(m.summary.untrusted, "2/2 reps untrusted: not quiet ×2 (busy up to 6.9 %)")
    XCTAssertTrue(m.reps.allSatisfy { $0.redone?.contains("not quiet") == true })
    XCTAssertEqual(Loop.exitCode(m), 5)
    let text = Measure.text(m)
    XCTAssertTrue(text.contains("mainThreadCpuMsPerStep: UNTRUSTED: 0/2 reps trusted (2/2 reps untrusted: not quiet ×2 (busy up to 6.9 %)): no number to quote"), text)
    XCTAssertFalse(text.contains("median"), text)
    XCTAssertTrue(text.contains("is not a number to quote"), text)
    XCTAssertTrue(m.next?.contains("once the Mac is quiet") == true, m.next ?? "")
    XCTAssertNil(store.ledger.entries().last?.objective, "no number in the ledger either")
    XCTAssertTrue(store.ledger.entries().last?.note?.contains("UNTRUSTED (2/2 reps untrusted") == true)

    // Some trusted: the median is theirs alone, and the rest are said.
    unsetenv("FAKE_ENV_QUIET")
    let ok = try loop.runScenario(options("champion", "step", reps: 1))
    XCTAssertEqual(ok.summary.trusted, 1); XCTAssertNil(ok.summary.untrusted)
  }

  func testAWindowWrongEveryTimeIsSaidOnceNotRerunForever() throws {
    try baseline()
    let cand = try bench("cand", ["KEY": "false"])
    let m = try loop.runScenario(options(cand, "step", reps: 3))
    XCTAssertEqual(runs().count, 4, "the first rep is redone once; the same window again isn't")
    XCTAssertEqual(m.summary.trusted, 0)
    XCTAssertEqual(m.summary.deterministic, "deterministic: window keyWindow=false in all 3 untrusted reps: a rerun won't change it")
    XCTAssertTrue(m.next?.hasPrefix("a rerun won't help") == true, m.next ?? "")
  }

  func testABaselineIsComparedWithOnceTheChampionHasItsScenario() throws {
    try baseline()
    let cand = try bench("cand", ["EXTRA": "toggle", "CPU": "20"])
    let b = try loop.runScenario(options(cand, "toggle", kind: "baseline"))
    XCTAssertEqual(b.kind, "baseline"); XCTAssertEqual(Loop.exitCode(b), 0)
    let rec = try XCTUnwrap(store.baseline("toggle"))
    XCTAssertEqual(rec.measurement, b.id); XCTAssertEqual(rec.median, b.summary.median); XCTAssertEqual(rec.trusted, 2); XCTAssertEqual(rec.fixture, "swarm64")
    XCTAssertEqual(rec.snapshot, "baselines/toggle/reference.png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.abs("baselines/toggle/reference.png")))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.abs("baselines/toggle/reference.later.png")))
    XCTAssertTrue(store.ledger.entries().last?.note?.contains("recorded as the baseline of toggle") == true)
    XCTAssertEqual(store.ledger.entries().last?.state, "baseline", "its own state, not a run's `measure`")
    XCTAssertTrue(store.ledger.entries().last?.text.contains("m0001 baseline ") == true)
    XCTAssertNil(Stopping.budgetClock(store.ledger.currentSession(), now: Date().addingTimeInterval(5 * 3600)), "no optimisation: no clock")
    XCTAssertTrue(b.next?.contains("perfloop run champion --scenario toggle compares it") == true, b.next ?? "")
    XCTAssertTrue(loop.status().contains("baselines waiting for a champion with their scenario: toggle (m0001)"), loop.status())

    // The feature lands: a champion that has the scenario. status says to compare; the baseline verb points at run.
    let landed = try store.add(try bench("landed", ["EXTRA": "toggle", "CPU": "22"]))
    try loop.setChampion(build: landed.build.hash!, merged: true, scenario: "step", fixture: "crew17")
    XCTAssertTrue(loop.status().contains("baseline toggle (m0001, latencyMs"), loop.status())
    XCTAssertTrue(loop.status().contains("perfloop run champion --scenario toggle compares it with the baseline"))
    XCTAssertThrowsError(try loop.runScenario(options(cand, "toggle", kind: "baseline"))) { XCTAssertTrue("\($0)".contains("the champion has toggle already"), "\($0)") }

    let r = try loop.runScenario(options("champion", "toggle"))
    let c = try XCTUnwrap(r.againstBaseline)
    XCTAssertEqual(c.measurement, "m0001"); XCTAssertEqual(c.median, rec.median); XCTAssertTrue(c.sameFixture)
    XCTAssertEqual(c.deltaPct, Stats.round((r.summary.median! - rec.median) / rec.median * 100, 1))
    XCTAssertEqual(r.snapshot?.pass, true, "the same picture as the baseline's")
    XCTAssertEqual(r.snapshot?.artifacts, [])
    XCTAssertTrue(Measure.text(r).contains("against the baseline m0001"), Measure.text(r))
    XCTAssertFalse(loop.status().contains("baseline toggle"), "compared: nothing left to say")

    // A champion that looks different: the pictures stay for a person, and nothing calls it a pass.
    let other = try store.add(try bench("other", ["EXTRA": "toggle", "SNAP": "changed"]))
    try loop.setChampion(build: other.build.hash!, merged: true, scenario: "step", fixture: "crew17")
    let d = try loop.runScenario(options("champion", "toggle", reps: 1))
    XCTAssertEqual(d.snapshot?.pass, false); XCTAssertEqual(d.snapshot?.review, true)
    XCTAssertEqual(d.snapshot?.artifacts.count, 3)
    for a in d.snapshot?.artifacts ?? [] { XCTAssertTrue(FileManager.default.fileExists(atPath: store.abs(a)), a) }
    XCTAssertTrue(d.next?.contains("look at the two pictures") == true, d.next ?? "")
  }

  func testNoBaselineFromUntrustedReps() throws {
    try baseline()
    setenv("FAKE_ENV_QUIET", "false", 1)
    let b = try loop.runScenario(options(try bench("cand", ["EXTRA": "toggle"]), "toggle", kind: "baseline", reps: 1))
    XCTAssertNil(store.baseline("toggle"))
    XCTAssertEqual(Loop.exitCode(b), 5)
    XCTAssertTrue(b.next?.contains("no baseline was recorded") == true, b.next ?? "")
    XCTAssertTrue(store.ledger.entries().last?.note?.contains("no baseline recorded") == true)
    XCTAssertEqual(store.ledger.entries().last?.state, "baseline", "a baseline that recorded nothing is still a baseline's line")
  }

  func testAReferenceRunsBesideEachRepInTheSameMinutes() throws {
    try baseline()
    let cand = try bench("cand", ["EXTRA": "toggle", "CPU": "20"])
    var o = options(cand, "toggle", kind: "baseline"); o.reference = "step"
    let b = try loop.runScenario(o)
    XCTAssertEqual(runs(), ["run step crew17", "run toggle swarm64", "run toggle swarm64", "run step crew17"], "counterbalanced: the reference first, then second")
    XCTAssertEqual(b.reps.map(\.order), ["after", "before"])
    let r = try XCTUnwrap(b.reference)
    XCTAssertEqual(r.scenario, "step"); XCTAssertEqual(r.fixture, "crew17"); XCTAssertEqual(r.experiment, "0000"); XCTAssertEqual(r.summary.trusted, 2)
    let champExe = try store.entry(store.champion()!.build.hash!).executable
    XCTAssertTrue(adapterCalls("run").filter { $0.hasPrefix("run step") }.allSatisfy { $0.hasSuffix(champExe) })
    XCTAssertEqual(store.baseline("toggle")?.referenceScenario, "step")
    XCTAssertTrue(Measure.text(b).contains("reference step on the champion 0000 (crew17), the same minutes: mainThreadCpuMsPerStep: "), Measure.text(b))

    // A later run with the same reference is put against the baseline in the reference's terms too.
    let x = try loop.runScenario(o.with { $0.kind = "run" })
    XCTAssertNotNil(x.againstBaseline?.normalisedDeltaPct)
    XCTAssertEqual(x.againstBaseline?.referenceScenario, "step")

    var bad = options(cand, "toggle"); bad.reference = "nope"
    XCTAssertThrowsError(try loop.runScenario(bad)) { XCTAssertTrue("\($0)".contains("unknown reference scenario 'nope'; the champion's manifest has step, switch"), "\($0)") }
  }

  // MARK: fixtures (F8)

  func testAnUnknownFixtureIsRefusedWithTheList() throws {
    try baseline()
    var n = Loop.NewOptions(hypothesis: "h"); n.bench = try bench("cand", ["CPU": "8"]); n.fixture = "crew71"
    XCTAssertThrowsError(try loop.new(n)) { XCTAssertEqual("\($0)", "unknown fixture 'crew71'; the champion's manifest has crew17, swarm64") }
    n.fixture = nil; n.secondFixture = "swarm46"
    XCTAssertThrowsError(try loop.new(n)) { XCTAssertTrue("\($0)".contains("unknown fixture 'swarm46'"), "\($0)") }
    var o = options("champion", "step"); o.fixture = "crew71"
    XCTAssertThrowsError(try loop.runScenario(o)) { XCTAssertTrue("\($0)".contains("unknown fixture 'crew71'; champion's manifest has crew17, swarm64"), "\($0)") }
    XCTAssertThrowsError(try loop.setChampion(build: store.champion()!.build.hash!, merged: true, scenario: "step", fixture: "nope"))
    XCTAssertTrue(adapterCalls("run").isEmpty && adapterCalls("ab").isEmpty, "refused before any window")
    // A parametric spec of a listed fixture passes.
    o.fixture = "crew17@agents=3"; o.reps = 1
    XCTAssertEqual(try loop.runScenario(o).summary.trusted, 1)
  }

  func testAFileFixtureMustBeThereBeforeAnyRep() throws {
    try baseline()
    let path = tmp.appendingPathComponent("fixtures/big.json").path
    let why = "no readable file at \(path) on this Mac: every rep would fail on it. Give the path of a file that exists, or create it first"
    var n = Loop.NewOptions(hypothesis: "h"); n.bench = try bench("cand", ["CPU": "8"]); n.fixture = "file:" + path; n.screen = false
    XCTAssertThrowsError(try loop.new(n)) { e in
      XCTAssertEqual((e as? PLError)?.code, 1); XCTAssertEqual("\(e)", "fixture file:\(path): " + why)
    }
    XCTAssertEqual(store.experiments().map(\.id), ["0000"], "refused before an experiment (or a build) was made")
    var o = options("champion", "step", reps: 1); o.fixture = "file:" + path
    XCTAssertThrowsError(try loop.runScenario(o)) { XCTAssertEqual("\($0)", "fixture file:\(path): " + why) }
    o.fixture = "file:no/such.json"
    XCTAssertThrowsError(try loop.runScenario(o)) { XCTAssertTrue("\($0)".contains("(a relative path is read from the directory perfloop runs in, "), "\($0)") }
    o.fixture = "file:~/no-such.json"
    XCTAssertThrowsError(try loop.runScenario(o)) { XCTAssertTrue("\($0)".contains("nothing expands ~ on the way to the adapter"), "\($0)") }
    XCTAssertTrue(store.measurements().isEmpty && !FileManager.default.fileExists(atPath: store.root.appendingPathComponent("runs").path), "no measurement started")
    XCTAssertTrue(adapterCalls("run").isEmpty && adapterCalls("ab").isEmpty, "refused before any window")

    // Once it's there, it runs: a scheme isn't on the manifest's list and needn't be.
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try "{}".write(toFile: path, atomically: true, encoding: .utf8)
    o.fixture = "file://" + path
    XCTAssertEqual(try loop.runScenario(o).summary.trusted, 1)
    let e = try loop.new(n)
    XCTAssertEqual(e.fixture, "file:" + path)
    // Each stage asks again, on its own runner: the file went away since exp new.
    try FileManager.default.removeItem(atPath: path)
    XCTAssertThrowsError(try loop.screen(e.id)) { XCTAssertEqual("\($0)", "fixture file:\(path): " + why) }
    XCTAssertTrue(adapterCalls("ab").isEmpty)
    XCTAssertEqual(try store.experiment(e.id).state, .built, "nothing decided")
  }

  func testAnAdapterThatNamesItsSchemesRefusesAnother() throws {
    try baseline(["SCHEMES": "file"])
    var o = options("champion", "step", reps: 1); o.fixture = "s3:bucket/x"
    XCTAssertThrowsError(try loop.runScenario(o)) {
      XCTAssertEqual("\($0)", "fixture 's3:bucket/x': the adapter takes no s3: fixtures (champion's manifest has fixtureSchemes file:); its fixtures are crew17, swarm64")
    }
    var n = Loop.NewOptions(hypothesis: "h"); n.bench = try bench("cand", ["CPU": "8", "SCHEMES": "file"]); n.fixture = "s3:bucket/x"
    XCTAssertThrowsError(try loop.new(n)) { XCTAssertTrue("\($0)".contains("the adapter takes no s3: fixtures (the champion's manifest"), "\($0)") }
    XCTAssertTrue(adapterCalls("run").isEmpty && adapterCalls("ab").isEmpty)
  }

  func testAScenariosOwnFixtureIsItsDefault() throws {
    // champion set without --fixture: the scenario's own, not the first listed.
    let e = try store.add(try bench("base", ["STEP_FIXTURE": "swarm64", "EXTRA": "toggle"]))
    try loop.setChampion(build: e.build.hash!, merged: true, scenario: "step", fixture: nil)
    XCTAssertEqual(try store.experiment("0000").fixture, "swarm64")
    // exp new on another scenario: that scenario's own fixture, not the champion's.
    var n = Loop.NewOptions(hypothesis: "h"); n.bench = try bench("cand", ["CPU": "8", "EXTRA": "toggle"]); n.scenario = "toggle"; n.screen = false
    XCTAssertEqual(try loop.new(n).fixture, "swarm64")
    n.scenario = "switch"
    XCTAssertEqual(try loop.new(n).fixture, "swarm64", "no fixture of its own: the champion's, as before")
  }

  func testAFixtureTheAdapterDidntRunDecidesNothing() throws {
    try baseline()
    let m = try loop.runScenario(options(try bench("cand", ["EXTRA": "toggle", "RAN_FIXTURE": "crew17"]), "toggle"))
    XCTAssertEqual(runs().count, 2, "not redone: it would run the wrong fixture again")
    XCTAssertTrue(m.reps.allSatisfy { $0.failure?.hasPrefix("ran fixture crew17, asked for swarm64") == true }, "\(m.reps.map(\.failure))")
    XCTAssertEqual(Loop.exitCode(m), 2)
    // In a pair too: the side that ran another fixture has no numbers for this one.
    var n = Loop.NewOptions(hypothesis: "h"); n.bench = try bench("cand2", ["CPU": "8", "RAN_FIXTURE": "swarm64"]); n.via = "run"
    let e = try loop.new(n)
    XCTAssertEqual(e.screen?.verdict, "error")
    XCTAssertTrue(e.screen?.pairs.first?.failure?.hasPrefix("the candidate ran fixture swarm64, asked for crew17") == true, "\(e.screen?.pairs.first?.failure ?? "")")
  }

  static func pictures(_ dir: URL) -> [URL] { Loop.pictures(under: dir) }
}

extension Loop.MeasureOptions {
  func with(_ f: (inout Self) -> Void) -> Self { var x = self; f(&x); return x }
}

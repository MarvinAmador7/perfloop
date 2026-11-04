import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// The experiment verbs end to end against the fake adapter: new → screen → full → promote → explain, resume,
/// guards, refusals, knobs, stale diffs, the replay.
final class LoopTests: FakeBenchCase {
  func testEndToEndAWinIsPromoted() throws {
    let base = try baseline()
    var o = Loop.NewOptions(hypothesis: "sizeThatFits answers itself")
    o.bench = try bench("cand", ["CPU": "8", "COMMIT": "e6d3625"]); o.screen = false
    var e = try loop.new(o)
    XCTAssertEqual(e.id, "0001"); XCTAssertEqual(e.state, .built); XCTAssertEqual(e.scenario, "step"); XCTAssertEqual(e.fixture, "crew17")
    XCTAssertEqual(e.secondFixture, "swarm64"); XCTAssertEqual(e.parent?.experiment, "0000"); XCTAssertEqual(e.via, "ab")

    e = try loop.screen(e.id)
    XCTAssertEqual(e.state, .promising, "\(e.screen!.reasons)")
    XCTAssertEqual(e.screen?.pairs.map(\.order), ["AB", "BA", "AB"])
    XCTAssertEqual(e.screen?.wins, 3)
    let abs = adapterCalls("ab")
    XCTAssertEqual(abs.count, 3)
    XCTAssertTrue(abs[0].contains("A=\(base.executable)")); XCTAssertTrue(abs[1].hasSuffix("B=\(base.executable)"))   // champion first, then second

    e = try loop.full(e.id)
    XCTAssertEqual(e.state, .won, "\(e.full!.reasons)")
    XCTAssertEqual(e.full?.repsPerSide, 5); XCTAssertEqual(e.full!.mwuP!, 2.0 / 252, accuracy: 1e-5)
    XCTAssertEqual(e.secondScreen?.fixture, "swarm64"); XCTAssertEqual(e.secondScreen?.notWorse, true)

    e = try loop.promote(e.id)
    XCTAssertEqual(e.state, .promoted)
    let c = try XCTUnwrap(store.champion())
    XCTAssertEqual(c.experiment, "0001"); XCTAssertEqual(c.parents, ["0000"]); XCTAssertEqual(c.mergedAncestor, "3a6b5b7"); XCTAssertFalse(c.merged)
    XCTAssertEqual(c.objectives["step"]!, 8, accuracy: 0.5)

    let text = try String(contentsOfFile: store.abs("exp/0001/explain.txt"), encoding: .utf8)
    XCTAssertTrue(text.contains("exp 0001 · promoted"))
    XCTAssertTrue(text.contains("screen: PROMISING")); XCTAssertTrue(text.contains("full: WON"))
    XCTAssertTrue(text.contains("next: open a PR"))
    XCTAssertEqual(store.ledger.entries().map(\.state), ["promoted", "built", "promising", "full", "won", "promoted"])
    XCTAssertEqual(store.ledger.entries().last?.objective?.before ?? 0, 40, accuracy: 2)

    // The next experiment climbs on the unmerged champion; the owner then merges and the chain restarts.
    var o2 = Loop.NewOptions(hypothesis: "heads first"); o2.bench = try bench("cand2", ["CPU": "1.5"]); o2.screen = false
    XCTAssertEqual(try loop.new(o2).parent?.experiment, "0001")
    XCTAssertEqual(try loop.markMerged(commit: "9bcd41a").chain, "0001 (merged 9bcd41a)")
    XCTAssertThrowsError(try loop.promote("0002"))                      // not won (not even screened)
  }

  func testScreenResumesAtTheFirstMissingPair() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["CPU": "8"]); o.screen = false
    let e = try loop.new(o)
    let s = try loop.sides(e)
    // An interrupted screen: pair 1 was written, then the process died.
    _ = try loop.pairs(e, stage: "screen", fixture: e.fixture, count: 1, sides: s, metric: "mainThreadCpuMsPerStep")
    XCTAssertEqual(adapterCalls("ab").count, 1)
    XCTAssertEqual(try loop.screen(e.id).state, .promising)
    XCTAssertEqual(adapterCalls("ab").count, 3)                          // 2 more, not 3
    XCTAssertEqual(try loop.screen(e.id).state, .promising)              // screened: nothing re-run
    XCTAssertEqual(adapterCalls("ab").count, 3)
  }

  func testSameBuildBehaviourIsNotARegression() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "a rebuild of the same code"); o.bench = try bench("same", ["CPU": "40"])
    let e = try loop.new(o)                                              // screens by default
    XCTAssertEqual(e.state, .rejected)
    XCTAssertNotEqual(try loop.full(e.id, force: true).full?.regression, true)
  }

  func testGuardsVetoAndPromotionRefusals() throws {
    try baseline()
    // A blank column is fast: the guard the champion's manifest names (landed) fails on the candidate.
    var o = Loop.NewOptions(hypothesis: "skip building the columns"); o.bench = try bench("cheat", ["CPU": "4", "CHECK_FAIL": "landed"])
    let cheat = try loop.new(o)
    XCTAssertEqual(cheat.state, .rejected); XCTAssertFalse(cheat.screen!.guardsPassed)
    XCTAssertThrowsError(try loop.full(cheat.id)) { XCTAssertEqual(($0 as? PLError)?.code, 6) }

    // A dirty build wins but isn't promoted; a declared behaviour change needs the owner.
    var d = Loop.NewOptions(hypothesis: "uncommitted"); d.bench = try bench("dirty", ["CPU": "8", "DIRTY": "true"]); d.behaviourChange = true
    let dirty = try loop.full(try loop.new(d).id)
    XCTAssertEqual(dirty.state, .won)
    XCTAssertThrowsError(try loop.promote(dirty.id)) { e in
      XCTAssertEqual((e as? PLError)?.code, 6); XCTAssertTrue("\(e)".contains("dirty")); XCTAssertTrue("\(e)".contains("owner"))
    }
    var po = Loop.PromoteOptions(); po.allowDirty = true
    XCTAssertThrowsError(try loop.promote(dirty.id, po)) { XCTAssertTrue("\($0)".contains("behaviour change")) }
    po.owner = true
    XCTAssertEqual(try loop.promote(dirty.id, po).state, .promoted)
    XCTAssertEqual(store.ledger.entries().last?.by, "owner")
  }

  func testWorseOnTheSecondFixtureIsLost() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "fast for 17, slow for 64"); o.bench = try bench("overfit", ["CPU": "8", "SWARM": "20"])
    let e = try loop.full(try loop.new(o).id)
    XCTAssertEqual(e.state, .lost); XCTAssertEqual(e.secondScreen?.notWorse, false)
  }

  func testAKnobExperimentRunsOneChildPerSide() throws {
    try baseline(["CLIP_DIV": "5"])
    var o = Loop.NewOptions(hypothesis: "clip-view scrolling instead of CA slides"); o.knobs = ["reel.slide": "clip"]
    let e = try loop.new(o)
    XCTAssertEqual(e.kind, "knob"); XCTAssertEqual(e.via, "run"); XCTAssertEqual(e.state, .promising)
    let runs = adapterCalls("run")
    XCTAssertEqual(runs.count, 6); XCTAssertEqual(runs.filter { $0.contains("knobs=reel.slide=clip") }.count, 3)
    var bad = Loop.NewOptions(hypothesis: "x"); bad.knobs = ["reel.slide": "spring"]
    XCTAssertThrowsError(try loop.new(bad)) { XCTAssertTrue("\($0)".contains("doesn't take")) }
    let won = try loop.full(e.id)
    XCTAssertEqual(won.state, .won)
    XCTAssertEqual(try loop.promote(won.id).notes.filter { $0.contains("knob debt") }.count, 1)
    XCTAssertEqual(store.champion()?.knobs, ["reel.slide": "clip"])
  }

  func testDiffRefusesATraceOfAnotherBuild() throws {
    let old = try store.add(try bench("old", ["CPU": "60", "COMMIT": "3a6b5b7"]))
    let champ = try store.add(try bench("v3", ["CPU": "20", "COMMIT": "e6d3625"]))
    try loop.setChampion(build: champ.build.hash!, merged: true, scenario: "step", fixture: "crew17")
    let trace = tmp.appendingPathComponent("base-step-time.trace").path, mine = tmp.appendingPathComponent("v3-step-time.trace").path
    FileManager.default.createFile(atPath: trace, contents: Data()); FileManager.default.createFile(atPath: mine, contents: Data())
    try loop.register(trace: trace, build: old.build.hash!); try loop.register(trace: mine, build: champ.build.hash!)
    XCTAssertThrowsError(try loop.diff(trace, mine, exp: nil, allowStale: false)) { e in
      XCTAssertEqual((e as? PLError)?.code, 6); XCTAssertTrue("\(e)".contains("trace build 3a6b5b7 ≠ champion e6d3625"), "\(e)")
    }
    XCTAssertTrue(try loop.diff(trace, mine, exp: nil, allowStale: true).contains("deskbench.diff/1"))
    XCTAssertThrowsError(try loop.diff(tmp.appendingPathComponent("unknown.trace").path, mine, exp: nil, allowStale: false))
  }

  func testPairsAreCounterbalanced() {
    let l = Loop(store: store)
    for key in ["0001/screen", "0002/screen", "0001/full"] {
      let orders = (0..<10).map { l.championFirst(key, $0) }
      XCTAssertEqual(orders.filter { $0 }.count, 5, key)               // 5 + 5 each way
      XCTAssertEqual(orders, (0..<10).map { l.championFirst(key, $0) }) // the same on resume
    }
    let starts = (0..<40).map { l.championFirst(String(format: "%04d/screen", $0), 0) }
    XCTAssertTrue(starts.contains(true) && starts.contains(false))     // the first side varies across experiments
  }

  /// An adapter without `ab` (a PerfLoopHost bench): pairs are measured through `run`, no `--via` needed.
  func testAnAdapterWithoutAbIsMeasuredThroughRun() throws {
    let verbs = ["VERBS": "help,list,describe,knobs,run,snapdiff"]
    try baseline(verbs)
    var o = Loop.NewOptions(hypothesis: "rows rank from an index"); o.bench = try bench("fast", verbs.merging(["CPU": "20"]) { $1 })
    let e = try loop.new(o)
    XCTAssertEqual(e.via, "run")
    XCTAssertEqual(e.state, .promising)
    XCTAssertTrue(adapterCalls("ab").isEmpty)
    XCTAssertEqual(adapterCalls("run").count, 6, "3 pairs, one child per side")
    // deskbench's manifest has no `verbs`: it keeps its own ab.
    XCTAssertEqual(store.champion().flatMap { try? store.entry($0.build.hash!).manifest?.defaultVia }, "run")
    XCTAssertEqual(Manifest(app: "a", adapter: "a", build: nil, scenarios: []).defaultVia, "ab")
  }

  func testPatchesNeverCarrySecrets() {
    XCTAssertThrowsError(try loop.checkPatch("diff --git a/.relay/token b/.relay/token\n+x\n"))
    XCTAssertThrowsError(try loop.checkPatch("diff --git a/bench/x.trace b/bench/x.trace\n"))
    XCTAssertNoThrow(try loop.checkPatch("diff --git a/Sources/Reel.swift b/Sources/Reel.swift\n+x\n"))
  }

  func testReplayAgainstFakes() throws {
    let root = tmp.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (n, cpu) in [("base", "40"), ("v1", "40"), ("v2", "10"), ("v3", "2")] {
      try FileManager.default.moveItem(atPath: try bench(n, ["CPU": cpu, "STAMP": "0"]), toPath: root.appendingPathComponent("\(n)-dir").path)
    }
    try "".write(to: root.appendingPathComponent("base.trace"), atomically: true, encoding: .utf8)
    let plan = ReplayPlan(schema: "perfloop.replay/1", app: "fake-replay", root: root.path, fixture: "crew17", via: "run",
                          builds: ["base", "v1", "v2", "v3"].map { ReplayBuild(name: $0, dir: "\($0)-dir", commit: "c79350e", dirty: true, note: "\($0)", confirmed: true) },
                          champion: "base",
                          steps: [ReplayStep(do: "exp", build: "v1", hypothesis: "flags", scenario: "step", expect: "rejected"),
                                  ReplayStep(do: "exp", build: "v2", hypothesis: "AppKit reel", scenario: "step", expect: "won|lost"),
                                  ReplayStep(do: "check", scenario: "step", a: "v1", b: "v2", expect: "rate change"),
                                  ReplayStep(do: "diff", build: "base", a: "trace:base.trace", b: "champion", expect: "refused"),
                                  ReplayStep(do: "exp", build: "v3", hypothesis: "slides", scenario: "step", expect: "promoted"),
                                  ReplayStep(do: "exp", build: "v3", hypothesis: "heads first", scenario: "switch", screenOnly: true, expect: "promising|rejected")],
                          session: .init(abRuns: 16, abMinutes: 48, recordings: 40, recordingMinutes: 10, promotions: ["v2", "v3"]),
                          costs: .init(screenS: 40, fullS: 180, confirmationS: 60, diffS: 15), notes: nil)
    let r = try loop.replay(plan)
    XCTAssertEqual(r.mismatches, 0, r.lines.joined(separator: "\n"))
    XCTAssertEqual(store.champion()?.chain.hasPrefix("0003 ← 0002 ← 0000"), true, r.lines.joined(separator: "\n"))
    XCTAssertTrue(r.lines.contains { $0.contains("LayoutEngineBox.sizeThatFits") })   // the worst stretch's top frame, no xctrace
    XCTAssertTrue(r.lines.contains { $0.contains("refused") && $0.contains("trace build c79350e ≠ champion") }, r.lines.joined(separator: "\n"))
  }
}

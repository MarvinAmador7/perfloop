import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// Untrusted reps never decide (ADAPTER.md §3, Trust), against the fake adapter: `ab`'s `runs[]` and `run`'s exit code,
/// window and quiet state reach the pair, an untrusted pair is redone once, a stage that needs it says UNTRUSTED and
/// is neither rejected nor lost, and a window wrong the same way on one side in both orders stops the stage.
final class TrustLoopTests: FakeBenchCase {
  override func tearDownWithError() throws { unsetenv("FAKE_ENV_QUIET"); try super.tearDownWithError() }

  func explain(_ id: String) throws -> String { try String(contentsOfFile: store.abs("exp/\(id)/explain.txt"), encoding: .utf8) }

  func testABusyMachineDecidesNothingAndOnlyItsPairsRunAgain() throws {
    try baseline()
    setenv("FAKE_ENV_QUIET", "false", 1)
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["CPU": "8", "BUSY": "99.8"])
    var e = try loop.new(o)
    XCTAssertEqual(e.state, .built, "never rejected on untrusted reps")
    XCTAssertEqual(e.screen?.verdict, "untrusted")
    XCTAssertEqual(adapterCalls("ab").count, 6, "3 pairs, each redone once")
    XCTAssertTrue(e.screen!.pairs.allSatisfy { $0.redone?.contains("not quiet") == true })
    XCTAssertEqual(e.screen?.pairs[0].b.busyPct, 99.8); XCTAssertEqual(e.screen?.pairs[0].b.busy, ["swift-build"]); XCTAssertEqual(e.screen?.pairs[0].a.exit, 0)
    let text = try explain(e.id)
    XCTAssertTrue(text.contains("screen: UNTRUSTED (6/6 reps untrusted: not quiet ×6 (busy up to 99.8 %: swift-build)) on mainThreadCpuMsPerStep"), text)
    XCTAssertTrue(text.contains("next: perfloop exp screen 0001 once the Mac is quiet"), text)
    XCTAssertFalse(text.contains("drop it"), text)
    XCTAssertFalse(store.ledger.entries().contains { $0.state == "rejected" })
    XCTAssertTrue(Stopping.reasons(StopInput(session: store.ledger.currentSession())).isEmpty)

    // Quiet again: the rerun measures the three untrusted pairs once each, and decides.
    unsetenv("FAKE_ENV_QUIET")
    e = try loop.screen(e.id)
    XCTAssertEqual(e.state, .promising, "\(e.screen!.reasons)")
    XCTAssertEqual(adapterCalls("ab").count, 9)
    XCTAssertNil(e.screen?.untrusted)
  }

  func testAnUntrustedFullIsResumedNotLost() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["CPU": "8"])
    var e = try loop.new(o)
    XCTAssertEqual(e.state, .promising)
    setenv("FAKE_ENV_QUIET", "false", 1)
    e = try loop.full(e.id)
    XCTAssertEqual(e.state, .full); XCTAssertEqual(e.full?.verdict, "untrusted")
    XCTAssertNil(e.secondScreen, "the second fixture waits for a full that decided")
    XCTAssertTrue(try explain(e.id).contains("next: perfloop exp full 0001 once the Mac is quiet"))
    XCTAssertThrowsError(try loop.promote(e.id))
    unsetenv("FAKE_ENV_QUIET")
    e = try loop.full(e.id)
    XCTAssertEqual(e.state, .won, "\(e.full!.reasons)")
  }

  func testTheBenchsOwnUntrustedExitNeverDecides() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["CPU": "8", "RUN_EXIT": "5"])
    let e = try loop.new(o)
    XCTAssertEqual(e.screen?.verdict, "untrusted")
    XCTAssertEqual(e.screen?.untrusted, "3/6 reps untrusted: exit 5 (the bench's own untrusted) ×3")
    XCTAssertTrue(Acceptance.unusable(e.screen!.pairs[0])!.contains("untrusted on the candidate: the bench exited 5"))
  }

  /// The palette case (F11): the candidate's window is never key while the champion's is, in both orders. A rerun can't
  /// change that: no redo once both orders agree, the stage stops, and nothing says "rerun".
  func testAOneSidedWindowFailureInBothOrdersStopsTheStage() throws {
    let verbs = ["VERBS": "help,list,describe,knobs,run,snapdiff"]
    try baseline(verbs)
    var o = Loop.NewOptions(hypothesis: "search in a panel"); o.bench = try bench("panel", verbs.merging(["CPU": "8", "KEY": "false", "RUN_EXIT": "5"]) { $1 })
    let e = try loop.new(o)
    XCTAssertEqual(e.via, "run"); XCTAssertEqual(e.state, .built)
    let s = try XCTUnwrap(e.screen)
    XCTAssertEqual(s.verdict, "untrusted")
    XCTAssertEqual(s.pairs.map(\.order), ["AB", "BA"], "stopped after both orders agreed")
    XCTAssertEqual(adapterCalls("run").count, 6, "pair 1 and its redo, pair 2 without one")
    XCTAssertNotNil(s.pairs[0].redone); XCTAssertNil(s.pairs[1].redone)
    XCTAssertEqual(s.pairs[1].b.windowFailed, ["keyWindow"]); XCTAssertEqual(s.pairs[1].b.exit, 5); XCTAssertEqual(s.pairs[1].a.exit, 0)
    let text = try explain(e.id)
    XCTAssertTrue(text.contains("unusable: untrusted on the candidate: window keyWindow=false (the champion's rep was fine)"), text)
    XCTAssertTrue(text.contains("deterministic: the candidate's window keyWindow=false in all 2 untrusted pairs, in both orders"), text)
    XCTAssertTrue(text.contains("next: a rerun won't help") && text.contains("key child window"), text)
    XCTAssertFalse(text.lowercased().contains("rerun perfloop") || text.contains(": rerun"), text)

    // Queued, it fails (a rerun can't help) instead of staying queued.
    try loop.queueAdd(e.id, stage: "screen", runner: "local")
    let res = try loop.queueRun(on: LocalRunner(), until: nil)
    XCTAssertEqual(loop.queue.items().first?.state, "failed", "\(res.lines)")
  }

  /// An `ab` that reports only summaries (no runs[], no reps): it still runs and decides, labelled unchecked.
  func testAnAbWithoutPerRepTrustStillRunsLabelledUnchecked() throws {
    try baseline(["NORUNS": "1"])
    var o = Loop.NewOptions(hypothesis: "h"); o.bench = try bench("cand", ["CPU": "8", "NORUNS": "1"])
    let e = try loop.new(o)
    XCTAssertEqual(e.state, .promising)
    XCTAssertNil(e.screen?.pairs[0].a.exit); XCTAssertNil(e.screen?.pairs[0].a.quiet)
    XCTAssertTrue(try explain(e.id).contains("trust: not checked"))
    // With runs[], it is checked: no such line.
    var o2 = Loop.NewOptions(hypothesis: "h2"); o2.bench = try bench("cand2", ["CPU": "8"])
    _ = try loop.new(o2)
    XCTAssertFalse(try explain("0002").contains("trust: not checked"))
  }
}

import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// Runners and the queue (C10) against the fake adapter: the ssh runner through fake ssh/rsync/open shims whose
/// "remote Mac" is a directory, and the idle-gated local runner with a scripted idle source.
final class RunnerTests: FakeBenchCase {
  static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
  var remoteHome: URL { tmp.appendingPathComponent("mini-home") }
  var sshLog: URL { tmp.appendingPathComponent("ssh.log") }

  override func setUpWithError() throws {
    try super.setUpWithError()
    let bin = tmp.appendingPathComponent("fakebin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("open"), withDestinationURL: Self.fixtures.appendingPathComponent("fake-open.sh"))
    try? FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("ioreg"), withDestinationURL: Self.fixtures.appendingPathComponent("fake-ioreg.sh"))
    setenv("FAKE_REMOTE_LOCKED", tmp.appendingPathComponent("mini-locked").path, 1)
    setenv("FAKE_REMOTE_HOME", remoteHome.path, 1); setenv("FAKE_BIN", bin.path, 1); setenv("FAKE_SSH_LOG", sshLog.path, 1)
  }
  override func tearDownWithError() throws {
    for k in ["FAKE_REMOTE_HOME", "FAKE_BIN", "FAKE_SSH_LOG", "FAKE_SSH_FAIL", "FAKE_REMOTE_LOCKED", "FAKE_REMOTE_IDLE"] { unsetenv(k) }
    try super.tearDownWithError()
  }

  func sshRunner(_ spec: String = "ssh://mar@fake-mini", launch: SSHRunner.Launch = .gui) throws -> SSHRunner {
    let r = try XCTUnwrap(try Runners.make(spec, store: store) as? SSHRunner)
    r.ssh = Self.fixtures.appendingPathComponent("fake-ssh.sh").path
    r.rsync = Self.fixtures.appendingPathComponent("fake-rsync.sh").path
    r.wake = false; r.launch = launch; r.waitPoll = 0.1; r.poll = 0.1
    return r
  }
  func sshCalls(_ prefix: String) -> [String] {
    ((try? String(contentsOf: sshLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
  }

  func candidate(cpu: String = "8", values: [String: String] = [:]) throws -> Experiment {
    var o = Loop.NewOptions(hypothesis: "faster"); o.bench = try bench("cand", ["CPU": cpu].merging(values) { $1 }); o.screen = false
    return try loop.new(o)
  }

  // MARK: ssh

  func testQueuedFullRunsOnTheSSHRunnerAndLandsInTheLedger() throws {
    try baseline(["GUARDED": "1"])
    let e = try candidate(values: ["GUARDED": "1"])
    let it = try loop.queueAdd(e.id, runner: "ssh://mar@fake-mini")
    XCTAssertEqual(it.runner, "ssh://fake-mini"); XCTAssertEqual(it.stage, "auto")
    XCTAssertThrowsError(try loop.queueAdd(e.id)) { XCTAssertEqual(($0 as? PLError)?.code, 6) }      // already queued

    let r = try sshRunner()
    let res = try loop.queueRun(on: r, until: nil)
    XCTAssertEqual(res.ran, 1, "\(res.lines)")
    let done = try store.experiment(e.id)
    XCTAssertEqual(done.state, .won, "\(done.full?.reasons ?? [])")
    XCTAssertEqual(done.screen?.runner?.runner, "ssh://fake-mini")
    XCTAssertEqual(done.full?.runner?.model, MachineModel.local())
    XCTAssertTrue(done.full!.pairs.allSatisfy { $0.runner?.runner == "ssh://fake-mini" })

    // The ledger keys the stages by runner and machine.
    let stages = store.ledger.entries().filter { ["promising", "won"].contains($0.state) }
    XCTAssertEqual(stages.count, 2)
    XCTAssertTrue(stages.allSatisfy { $0.runner == "ssh://fake-mini" && $0.machine == MachineModel.local() })

    // The adapter ran there, on the runner's copies of the builds, in the GUI-session launcher.
    let remoteRoot = remoteHome.appendingPathComponent(".perfloop/fake-app").path
    let abs = adapterCalls("ab")
    XCTAssertFalse(abs.isEmpty)
    XCTAssertTrue(abs.allSatisfy { $0.contains("A=\(remoteRoot)/builds/") && $0.contains("B=\(remoteRoot)/builds/") }, abs[0])
    XCTAssertFalse(sshCalls("open ").isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: remoteHome.appendingPathComponent(".perfloop/.runner/PerfLoopLauncher.app/Contents/MacOS/launch").path))
    // Two builds there, by hash, copied once each; no results left behind.
    let builds = try FileManager.default.contentsOfDirectory(atPath: remoteRoot + "/builds").filter { !$0.hasPrefix(".") }
    XCTAssertEqual(Set(builds), Set([done.build!.hash!, done.parent!.build.hash!].map { String($0.dropFirst(7)) }))
    XCTAssertEqual(sshCalls("rsync -a /").count, 2)
    let left = FileManager.default.enumerator(atPath: remoteRoot + "/exp")?.allObjects.compactMap { $0 as? String }.filter { $0.hasSuffix(".json") } ?? []
    XCTAssertEqual(left, [])

    // Results came back with the store's paths: the raw outputs, and the guards' artifacts.
    let raw = try String(contentsOfFile: store.abs(done.full!.pairs[0].result!), encoding: .utf8)
    XCTAssertFalse(raw.contains(remoteRoot)); XCTAssertTrue(raw.contains(store.root.path))
    XCTAssertTrue(done.full!.pairs.allSatisfy { $0.b.guards?.first { $0.name == GuardNames.snapshotDiff }?.pass == true })

    let q = loop.queue.items()
    XCTAssertEqual(q.map(\.state), ["done"]); XCTAssertEqual(q[0].ranOn, "ssh://fake-mini")
    XCTAssertTrue(loop.explain(done).contains("ran on ssh://fake-mini"))
    XCTAssertEqual(try loop.queueRun(on: try sshRunner(), until: nil).lines, ["nothing queued for ssh://fake-mini"])
  }

  func testALockedRemoteScreenWaitsUntilUnlocked() throws {
    try baseline()
    let e = try candidate(); try loop.queueAdd(e.id, stage: "screen")
    let locked = tmp.appendingPathComponent("mini-locked")
    FileManager.default.createFile(atPath: locked.path, contents: Data())
    XCTAssertTrue(try sshRunner().check().contains { $0.hasPrefix("screen: LOCKED") })
    let res = try loop.queueRun(on: try sshRunner(), until: Date().addingTimeInterval(1))
    XCTAssertNotNil(res.stopped)
    XCTAssertTrue(adapterCalls("ab").isEmpty)
    XCTAssertTrue(loop.queue.items()[0].lastWait?.contains("its screen is locked") == true, "\(loop.queue.items())")
    // Unlocked a moment later: the waiting runner goes on by itself.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { try? FileManager.default.removeItem(at: locked) }
    XCTAssertEqual(try loop.queueRun(on: try sshRunner(), until: nil).ran, 1)
    XCTAssertEqual(adapterCalls("ab").count, 3)
  }

  func testRemoteIdleGateAbortsARepOnInputThere() throws {
    try baseline(["SLEEP": "2"])
    let e = try candidate(values: ["SLEEP": "2"])
    let r = try sshRunner(); r.gate = IdleGate(threshold: 5)
    setenv("FAKE_REMOTE_IDLE", "100", 1)
    var waits: [String] = []
    r.onWait = { waits.append($0) }
    var once = false
    r.log = { line in if line.contains("copying") { return }; if !once, line.hasPrefix("ssh://fake-mini: mar") { once = true } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { setenv("FAKE_REMOTE_IDLE", "0.5", 1) }       // someone sits down at the mini
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { setenv("FAKE_REMOTE_IDLE", "100", 1) }       // and leaves
    loop.runner = r
    let x = try loop.screen(e.id)
    XCTAssertEqual(x.state, .promising, "\(x.screen?.reasons ?? [])")
    XCTAssertTrue(waits.contains { $0.contains("interrupted on fake-mini") }, "\(waits)")
    XCTAssertGreaterThanOrEqual(x.screen?.pairs.compactMap(\.interruptions).reduce(0, +) ?? 0, 1)
  }

  func testDirectLaunchAndRunVia() throws {
    try baseline()
    let e = try candidate()
    var x = e; x.via = "run"; try store.save(x)
    loop.runner = try sshRunner(launch: .direct)
    XCTAssertEqual(try loop.screen(e.id).state, .promising)
    XCTAssertTrue(sshCalls("open ").isEmpty)
    XCTAssertEqual(adapterCalls("run").count, 6)
  }

  func testSSHFailuresSayWhatToDo() throws {
    try baseline()
    for (mode, want) in [("auth", "refused this Mac's key"), ("hostkey", "isn't in ~/.ssh/known_hosts"), ("changed", "host key has changed"),
                         ("refused", "turn on Remote Login"), ("timeout", "can't reach fake-mini")] {
      setenv("FAKE_SSH_FAIL", mode, 1)
      XCTAssertThrowsError(try sshRunner().identity(), mode) { XCTAssertTrue("\($0)".contains(want), "\(mode): \($0)") }
    }
    unsetenv("FAKE_SSH_FAIL")
    // An unreachable runner fails its item and stops the queue instead of failing every item.
    let e = try candidate(); try loop.queueAdd(e.id)
    setenv("FAKE_SSH_FAIL", "timeout", 1)
    let res = try loop.queueRun(on: try sshRunner(), until: nil)
    XCTAssertEqual(loop.queue.items().map(\.state), ["failed"]); XCTAssertNotNil(res.stopped)
  }

  func testPathsInEverySpellingOfTheStoreMapToTheRunners() throws {
    // /private/tmp/x and /tmp/x are one directory; Foundation standardizes the first into the second.
    store = Store(root: URL(fileURLWithPath: "/private/tmp/pl-\(UUID().uuidString)/home/fake-app"))
    let r = try sshRunner(); r.remoteRoot = "/Users/mar/.perfloop/fake-app"
    let p = store.root.path
    XCTAssertEqual(r.map(p + "/builds/ab/X"), "/Users/mar/.perfloop/fake-app/builds/ab/X")
    XCTAssertEqual(r.map(String(p.dropFirst(8)) + "/exp/0001/screen"), "/Users/mar/.perfloop/fake-app/exp/0001/screen")
    XCTAssertEqual(r.map("--out=" + p + "/exp/1/p1.json"), "--out=/Users/mar/.perfloop/fake-app/exp/1/p1.json")
    XCTAssertEqual(r.map("/elsewhere/x"), "/elsewhere/x")
    XCTAssertEqual(r.unmap("{\"a\": \"/Users/mar/.perfloop/fake-app/exp/1/p1.json\"}"), "{\"a\": \"\(p)/exp/1/p1.json\"}")
  }

  func testRunnerSpecs() {
    XCTAssertEqual(RunnerSpec("ssh://mar@Marvins-Mac-mini.local"), .ssh(user: "mar", host: "Marvins-Mac-mini.local", port: nil, root: nil))
    XCTAssertEqual(RunnerSpec("ssh://mini:2222/Users/x/pl"), .ssh(user: nil, host: "mini", port: 2222, root: "/Users/x/pl"))
    XCTAssertEqual(RunnerSpec("ssh://mar@mini")?.name, "ssh://mini")
    XCTAssertNil(RunnerSpec("ssh://"))
    XCTAssertNil(RunnerSpec("ssh://a b"))
    XCTAssertEqual(RunnerSpec("vm:tart/seq"), .vm(tool: "tart", name: "seq"))
    XCTAssertThrowsError(try Runners.make("vm:tart/seq", store: store)) { XCTAssertTrue("\($0)".contains("not available")) }
  }

  // MARK: mixing runners

  func testAStageNeverMixesRunners() throws {
    try baseline()
    let e = try candidate()
    let s = try loop.sides(e)
    _ = try loop.pairs(e, stage: "screen", fixture: e.fixture, count: 1, sides: s, metric: "mainThreadCpuMsPerStep")   // pair 1 here
    loop.runner = try sshRunner()
    XCTAssertThrowsError(try loop.screen(e.id)) { XCTAssertEqual(($0 as? PLError)?.code, 6); XCTAssertTrue("\($0)".contains("results never mix runners"), "\($0)") }
    // And the acceptance rule refuses a stage whose pairs say they came from two machines.
    var p1 = Pair(index: 0, order: "AB", result: nil, a: Side(objective: 40), b: Side(objective: 8)), p2 = p1
    p1.runner = RunnerIdentity(runner: "local", model: "Mac16,1"); p2.index = 1; p2.runner = RunnerIdentity(runner: "ssh://mini", model: "Mac16,11")
    XCTAssertEqual(Acceptance.screen([p1, p2, p1], metric: "mainThreadCpuMsPerStep", guards: []).verdict, "error")
    XCTAssertEqual(Acceptance.full([p1, p2], metric: "mainThreadCpuMsPerStep", guards: [], lastLook: true).verdict, "error")
    var legacy = p1; legacy.runner = nil
    XCTAssertNil(RunnerIdentity.mixed([legacy, p1]))
  }

  // MARK: the idle-gated local runner

  /// Idle readings from a script: grows with the clock from `start`, reset by `touch()`.
  final class FakeIdle {
    var since = Date().addingTimeInterval(-1000)
    var locked = false
    func touch() { since = Date() }
    var source: ScriptedIdleSource { ScriptedIdleSource { [unowned self] in IdleReading(idle: Date().timeIntervalSince(self.since), frontmost: "Xcode", locked: self.locked) } }
  }

  func gated(_ idle: FakeIdle, threshold: Double = 0.6) -> LocalRunner {
    let r = LocalRunner(); r.gate = IdleGate(threshold: threshold); r.idle = idle.source; r.poll = 0.05
    return r
  }

  func testIdleGateWaitsThenRunsAndRedoesAnInterruptedRep() throws {
    try baseline(["SLEEP": "1"])
    let e = try candidate(values: ["SLEEP": "1"])
    let idle = FakeIdle(); idle.touch()                          // someone just typed
    let r = gated(idle)
    var waits: [String] = []
    r.onWait = { waits.append($0) }
    // Input once, 0.5 s into the first rep that runs.
    var touched = false
    r.log = { line in
      if line.hasPrefix("idle"), !touched { touched = true; DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { idle.touch() } }
    }
    loop.runner = r
    let x = try loop.screen(e.id)
    XCTAssertEqual(x.state, .promising, "\(x.screen?.reasons ?? [])")
    XCTAssertTrue(waits.first?.hasPrefix("waiting: last input 0 s ago") == true, "\(waits)")
    XCTAssertTrue(waits.contains { $0.hasPrefix("interrupted: input during the rep") }, "\(waits)")
    XCTAssertEqual(x.screen?.pairs.compactMap(\.interruptions).reduce(0, +), 1)
    XCTAssertEqual(adapterCalls("ab").count, 4)                     // 3 pairs + the aborted one
    XCTAssertTrue(loop.explain(x).contains("1 rep(s) interrupted by input and redone"))
    // The aborted ab and its children are gone.
    XCTAssertFalse(try Adapter.spawn("/bin/ps", ["-A", "-o", "command="], quiet: true).stdout.contains(store.root.path + "/builds"))
  }

  func testTheQueueLogsWhyItWaitedAndStopsAtTheDeadline() throws {
    try baseline()
    let e = try candidate(); try loop.queueAdd(e.id, stage: "screen", runner: "local")
    let idle = FakeIdle(); idle.locked = true
    let r = gated(idle, threshold: 120)
    let res = try loop.queueRun(on: r, until: Date().addingTimeInterval(0.4))
    XCTAssertNotNil(res.stopped)
    let it = try XCTUnwrap(loop.queue.items().first)
    XCTAssertEqual(it.state, "queued")                               // kept for next time
    XCTAssertTrue(it.lastWait?.contains("the screen is locked") == true, "\(it)")
    XCTAssertTrue(adapterCalls("ab").isEmpty)
    // Unlocked and idle long enough: it runs.
    idle.locked = false
    XCTAssertEqual(try loop.queueRun(on: gated(idle, threshold: 120), until: nil).ran, 1)
    XCTAssertEqual(loop.queue.items().first?.state, "done")
  }

  func testOneQueueRunPerRunner() throws {
    try baseline()
    let lock = try RunnerLock.acquire(store: store, runner: "local")
    XCTAssertThrowsError(try loop.queueRun(on: LocalRunner(), until: nil)) { XCTAssertTrue("\($0)".contains("busy"), "\($0)") }
    lock.release()
    XCTAssertNoThrow(try loop.queueRun(on: LocalRunner(), until: nil))
  }
}

/// The pure half: the idle rule, --until, the queue's records.
final class RunnerKitTests: XCTestCase {
  func testIdleGate() {
    let g = IdleGate(threshold: 120)
    XCTAssertEqual(g.wait(IdleReading(idle: nil)), .unknown)
    XCTAssertEqual(g.wait(IdleReading(idle: 500, locked: true)), .locked)
    XCTAssertEqual(g.wait(IdleReading(idle: 500, frontmost: "zoom.us")), .busyApp("zoom.us"))
    XCTAssertEqual(g.wait(IdleReading(idle: 30, frontmost: "Xcode"))?.text(threshold: 120), "last input 30 s ago < 120 s (frontmost: Xcode)")
    XCTAssertNil(g.wait(IdleReading(idle: 121)))
    XCTAssertNil(g.interrupted(previous: IdleReading(idle: 130), now: IdleReading(idle: 130.5)))
    XCTAssertNotNil(g.interrupted(previous: IdleReading(idle: 130), now: IdleReading(idle: 0.2)))
    XCTAssertNotNil(g.interrupted(previous: IdleReading(idle: 130), now: IdleReading(idle: 131, locked: true)))
    XCTAssertEqual(IdleReading(text: "idle=12.5 frontmost=QuickTime_Player locked=0"), IdleReading(idle: 12.5, frontmost: "QuickTime Player", locked: false))
    XCTAssertEqual(IdleReading(text: "300\n"), IdleReading(idle: 300))
  }

  func testUntil() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-10-31T22:00:00Z")!
    XCTAssertEqual(Until.parse("07:00", now: now, calendar: cal), ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z"))
    XCTAssertEqual(Until.parse("23:30", now: now, calendar: cal), ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z"))
    XCTAssertNil(Until.parse("25:00", now: now, calendar: cal)); XCTAssertNil(Until.parse("7", now: now, calendar: cal))
  }

  func testQueueRecords() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plq-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let q = Queue(path: dir.appendingPathComponent("queue.jsonl").path)
    try q.append(QueueEvent(item: "q1", state: "queued", experiment: "0001", stage: "auto", runner: "ssh://mini"))
    try q.append(QueueEvent(item: "q2", state: "queued", experiment: "0002", stage: "screen"))
    XCTAssertEqual(q.nextID(), "q3")
    XCTAssertEqual(q.runnable(on: "local").map(\.id), ["q2"])
    XCTAssertEqual(q.runnable(on: "ssh://mini").map(\.id), ["q1", "q2"])
    try q.append(QueueEvent(item: "q1", state: "running", runner: "ssh://mini", note: "pid 1"))
    try q.append(QueueEvent(item: "q1", state: "waiting", note: "waiting on mini: last input 3 s ago < 120 s"))
    try q.append(QueueEvent(item: "q1", state: "stopped", note: "reached --until"))
    XCTAssertEqual(q.items().map(\.state), ["queued", "queued"])
    XCTAssertTrue(q.items()[0].lastWait?.contains("last input 3 s") == true)
    try q.append(QueueEvent(item: "q2", state: "done", runner: "local", note: "exp 0002 → promising"))
    XCTAssertTrue(Queue.text(q.items()).contains("q2   done     exp 0002 screen on any runner"))
  }
}

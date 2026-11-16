import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// The owner's flags on the CLI (OwnerGate): honoured with PERFLOOP_OWNER=1 or a yes at a terminal, refused otherwise
/// with the agent's own way on; every use recorded where a PR reads (experiment.json, the ledger, explain, status).
final class OwnerFlagTests: FakeBenchCase {
  func gate(env: [String: String] = [:], terminal: Bool = false, answer: String? = nil) -> (OwnerGate, () -> [String]) {
    var asked: [String] = []
    let g = OwnerGate(env: env, terminal: terminal, ask: { asked.append($0); return answer })
    return (g, { asked })
  }

  func testTheGateHonoursOnlyTheOwnersShell() throws {
    // No owner flag: nothing to check.
    XCTAssertNil(try gate().0.check(flags: ["runner", "idle", "json"], command: "exp full"))
    // PERFLOOP_OWNER=1.
    XCTAssertEqual(try gate(env: ["PERFLOOP_OWNER": "1"]).0.check(flags: ["force", "runner"], command: "exp full"),
                   OwnerAuth(flags: ["--force"], via: "env", command: "exp full"))
    // An agent's shell: no variable (or not 1), no terminal. Refused, with what to do instead and no way around.
    for env in [[:], ["PERFLOOP_OWNER": "0"], ["PERFLOOP_OWNER": "yes"]] {
      let (g, asked) = gate(env: env)
      XCTAssertThrowsError(try g.check(flags: ["force"], command: "exp full")) { e in
        XCTAssertEqual((e as? PLError)?.code, 6)
        let m = "\(e)"
        XCTAssertTrue(m.contains("--force is an owner flag"), m); XCTAssertTrue(m.contains("nothing ran"), m)
        XCTAssertTrue(m.contains("If you are an agent, stop: don't pass it,"), m); XCTAssertTrue(m.contains("don't set PERFLOOP_OWNER"), m)
        XCTAssertTrue(m.contains("drop the change"), m); XCTAssertTrue(m.contains("report it to the owner"), m)
      }
      XCTAssertEqual(asked(), [], "no terminal: no prompt")
    }
    // Each flag says what it does and the agent's own path.
    XCTAssertThrowsError(try gate().0.check(flags: ["owner", "allow-dirty"], command: "exp promote")) { e in
      let m = "\(e)"
      XCTAssertTrue(m.contains("--owner and --allow-dirty are owner flags (--owner: it acts as the owner"), m)
      XCTAssertTrue(m.contains("promotes a build with uncommitted changes"), m); XCTAssertTrue(m.contains("commit, rebuild"), m)
    }
    XCTAssertThrowsError(try gate().0.check(flags: ["force"], command: "queue run")) { XCTAssertTrue("\($0)".contains("--idle 120"), "\($0)") }
    XCTAssertThrowsError(try gate().0.check(flags: ["guard-tolerance"], command: "exp new")) { XCTAssertTrue("\($0)".contains("snapshot over tolerance"), "\($0)") }
  }

  func testATerminalAsksAndOnlyAYesGoesOn() throws {
    let (yes, asked) = gate(terminal: true, answer: " Yes ")
    XCTAssertEqual(try yes.check(flags: ["force"], command: "queue add"), OwnerAuth(flags: ["--force"], via: "tty", command: "queue add"))
    XCTAssertEqual(asked().count, 1)
    XCTAssertTrue(asked()[0].contains("--force is an owner flag: it queues a full"), asked()[0])
    XCTAssertTrue(asked()[0].contains("An agent answers no and asks the owner"), asked()[0])
    for answer in ["no", "y", "", nil] as [String?] {
      XCTAssertThrowsError(try gate(terminal: true, answer: answer).0.check(flags: ["force"], command: "exp full")) { e in
        XCTAssertEqual((e as? PLError)?.code, 6); XCTAssertTrue("\(e)".contains("not confirmed: nothing ran"), "\(e)")
      }
    }
    // The variable needs no prompt.
    let (env, asked2) = gate(env: ["PERFLOOP_OWNER": "1"], terminal: true)
    XCTAssertEqual(try env.check(flags: ["owner"], command: "exp promote")?.via, "env"); XCTAssertEqual(asked2(), [])
  }

  /// A screen-rejected candidate: no flag gets it a full, and the refusal gives the agent's path, not the flag.
  func rejected() throws -> Experiment {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "slower"); o.bench = try bench("slow", ["CPU": "60"])
    let e = try loop.new(o)
    XCTAssertEqual(e.state, .rejected)
    return e
  }

  func testARejectedScreenPointsAtTheAgentsPathAndAForcedFullIsRecorded() throws {
    let e = try rejected()
    for f in [{ try self.loop.full(e.id) }, { try self.loop.queueAdd(e.id) }] as [() throws -> Any] {
      XCTAssertThrowsError(try f()) { err in
        XCTAssertEqual((err as? PLError)?.code, 6)
        let m = "\(err)"
        XCTAssertTrue(m.contains("exp \(e.id) was rejected by its screen"), m); XCTAssertTrue(m.contains("Drop the change"), m)
        XCTAssertTrue(m.contains("perfloop explain exp/\(e.id)"), m); XCTAssertFalse(m.contains("--force"), m)
      }
    }
    // The owner forces it (PERFLOOP_OWNER=1): the full runs and says so everywhere.
    loop.owner = OwnerAuth(flags: ["--force"], via: "env", command: "exp full")
    let f = try loop.full(e.id, force: true)
    XCTAssertEqual(f.state, .lost)
    XCTAssertEqual(f.forced, true)
    let u = try XCTUnwrap(f.ownerFlags?.first)
    XCTAssertEqual(f.ownerFlags?.count, 1)
    XCTAssertEqual(u.flag, "--force"); XCTAssertEqual(u.via, "env"); XCTAssertEqual(u.command, "exp full")
    XCTAssertEqual(u.effect, "ran the full over a screen that rejected it")
    let saved = try store.experiment(e.id)
    XCTAssertEqual(saved.ownerFlags, f.ownerFlags, "in experiment.json")
    // The ledger: the full's lines carry it, the screen's line doesn't.
    let lines = store.ledger.entries().filter { $0.experiment == e.id }
    XCTAssertEqual(lines.map(\.state), ["built", "rejected", "full", "lost"])
    XCTAssertEqual(lines.map { $0.ownerFlags ?? [] }, [[], [], ["--force"], ["--force"]])
    XCTAssertTrue(lines.last!.text.contains("OWNER FLAG --force (PERFLOOP_OWNER=1)"), lines.last!.text)
    // The verdict and explain.txt.
    let text = try String(contentsOfFile: store.abs("exp/\(e.id)/explain.txt"), encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("exp \(e.id) · lost · code · step on crew17 (second fixture swarm64) · FORCED (owner flag)"), text)
    XCTAssertTrue(text.contains("owner flag: --force (PERFLOOP_OWNER=1, exp full, "), text)
    XCTAssertTrue(text.contains("): ran the full over a screen that rejected it"), text)
    // exp status: closed, but the session's owner flags are listed.
    XCTAssertTrue(loop.status().contains("owner flag: "), loop.status())
    XCTAssertEqual(loop.status().components(separatedBy: "OWNER FLAG --force").count, 2, "once per experiment: \(loop.status())")
    // Resuming it (or running it again) records nothing new.
    loop.owner = OwnerAuth(flags: ["--force"], via: "env", command: "exp full")
    _ = try loop.full(e.id, force: true)
    XCTAssertEqual(try store.experiment(e.id).ownerFlags?.count, 1)
  }

  func testAQueuedForceRecordsHowItWasAuthorisedWhenItRuns() throws {
    let e = try rejected()
    loop.owner = OwnerAuth(flags: ["--force"], via: "tty", command: "queue add")
    let it = try loop.queueAdd(e.id, force: true)
    XCTAssertEqual(it.forceVia, "tty")
    XCTAssertTrue(Queue.text([it]).contains("full --force (owner flag)") || Queue.text([it]).contains("auto --force (owner flag)"), Queue.text([it]))
    // `queue run` comes later, without any owner flag of its own.
    loop.owner = nil
    let res = try loop.queueRun(on: LocalRunner(), until: nil)
    XCTAssertEqual(res.ran, 1, "\(res.lines)")
    let x = try store.experiment(e.id)
    XCTAssertEqual(x.forced, true)
    XCTAssertEqual(x.ownerFlags?.map(\.via), ["tty"]); XCTAssertEqual(x.ownerFlags?.map(\.command), ["queue add --force"])
    XCTAssertEqual(store.ledger.entries().last?.ownerFlags, ["--force"]); XCTAssertEqual(store.ledger.entries().last?.ownerVia, "tty")
  }

  func testAnUngatedQueueRunIsRecordedOnWhatItRan() throws {
    try baseline()
    var o = Loop.NewOptions(hypothesis: "faster"); o.bench = try bench("fast", ["CPU": "8"]); o.screen = false
    let e = try loop.new(o)
    try loop.queueAdd(e.id, stage: "screen")
    loop.owner = OwnerAuth(flags: ["--force"], via: "env", command: "queue run")
    XCTAssertEqual(try loop.queueRun(on: LocalRunner(), until: nil).ran, 1)
    let x = try store.experiment(e.id)
    XCTAssertEqual(x.state, .promising); XCTAssertEqual(x.forced, true)
    XCTAssertEqual(x.ownerFlags?.first?.effect, "its reps started without the idle gate (queue run --force)")
    XCTAssertEqual(store.ledger.entries().last?.ownerFlags, ["--force"])
    XCTAssertTrue(loop.status().contains("faster · FORCED (owner flag)"), loop.status())
  }

  func testWhatWaitsForTheOwnerNeverAdvertisesTheirFlags() throws {
    try baseline()
    var d = Loop.NewOptions(hypothesis: "a new look"); d.bench = try bench("look", ["CPU": "8"]); d.behaviourChange = true
    let won = try loop.full(try loop.new(d).id)
    XCTAssertEqual(won.state, .won)
    XCTAssertThrowsError(try loop.promote(won.id)) { e in
      let m = "\(e)"
      XCTAssertTrue(m.contains("it waits for the owner (a declared behaviour change): stop and ask them"), m); XCTAssertFalse(m.contains("--owner"), m)
    }
    var shapes = [won]
    var x = won; x.state = .needsReview; shapes.append(x)
    x.build?.dirty = true; x.state = .won; shapes.append(x)
    for s in shapes {
      let n = Explain.next(s)
      for f in ["--owner", "--guard-tolerance", "--force", "--allow-dirty"] { XCTAssertFalse(n.contains(f), "\(s.state): \(n)") }
    }
  }

  func testMCPChildrenNeverSeeTheOwnersVariable() {
    setenv("PERFLOOP_OWNER", "1", 1); defer { unsetenv("PERFLOOP_OWNER") }
    let s = MCPServer(cli: "/bin/echo", jobsDir: tmp.appendingPathComponent("jobs"))
    s.env = ["PERFLOOP_OWNER": "1", "OTHER": "x"]
    XCTAssertNil(s.childEnv["PERFLOOP_OWNER"]); XCTAssertEqual(s.childEnv["OTHER"], "x")
  }
}

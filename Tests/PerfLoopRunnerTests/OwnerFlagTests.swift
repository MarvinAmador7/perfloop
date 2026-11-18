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
        XCTAssertEqual((e as? PLError)?.code, 6); XCTAssertTrue("\(e)".contains("not confirmed (only a typed yes confirms): nothing ran"), "\(e)")
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

  // MARK: the champion

  func testChampionSetIsTheOwnersAndPassesTheSameGate() throws {
    // An agent's shell: refused, with the agent's own way (a win, promoted), and nothing ran.
    for env in [[:], ["PERFLOOP_OWNER": "0"]] {
      let (g, asked) = gate(env: env)
      XCTAssertThrowsError(try g.check(command: "champion set")) { e in
        XCTAssertEqual((e as? PLError)?.code, 6)
        let m = "\(e)"
        XCTAssertTrue(m.contains("`perfloop champion set` is the owner's: it picks the champion, the build every later verdict is judged against"), m)
        XCTAssertTrue(m.contains("nothing ran"), m); XCTAssertTrue(m.contains("If you are an agent, stop: don't run it, don't set PERFLOOP_OWNER"), m)
        XCTAssertTrue(m.contains("only when one of your experiments wins and is promoted (perfloop exp promote ID)"), m)
        XCTAssertTrue(m.contains("ask the owner to set it"), m)
      }
      XCTAssertEqual(asked(), [])
    }
    // The owner: the variable, or a yes at a terminal (and only a yes).
    XCTAssertEqual(try gate(env: ["PERFLOOP_OWNER": "1"]).0.check(command: "champion set"), OwnerAuth(flags: ["champion set"], via: "env", command: "champion set"))
    let (yes, asked) = gate(terminal: true, answer: "yes")
    XCTAssertEqual(try yes.check(command: "champion set").via, "tty")
    XCTAssertTrue(asked()[0].contains("`perfloop champion set` is the owner's"), asked()[0])
    XCTAssertThrowsError(try gate(terminal: true, answer: "y").0.check(command: "champion set")) { XCTAssertTrue("\($0)".contains("champion set not confirmed"), "\($0)") }
    // exp replay --go sets the plan's champion: the same gate.
    XCTAssertThrowsError(try gate().0.check(command: "exp replay")) { e in
      XCTAssertTrue("\(e)".contains("sets the plan's champion"), "\(e)"); XCTAssertTrue("\(e)".contains("--dry-run"), "\(e)")
    }
  }

  func testTheGateSaysATypedYesIsTheOnlyConfirmation() throws {
    let (g, asked) = gate(terminal: true, answer: nil)
    XCTAssertThrowsError(try g.check(flags: ["force"], command: "exp full")) { XCTAssertTrue("\($0)".contains("not confirmed (only a typed yes confirms): nothing ran"), "\($0)") }
    XCTAssertTrue(asked()[0].contains("Type yes to go on (anything else stops it; this typed yes is the only confirmation perfloop asks for)"), asked()[0])
    XCTAssertThrowsError(try gate().0.check(flags: ["force"], command: "exp full")) { e in
      let m = "\(e)"
      XCTAssertTrue(m.contains("no terminal to type yes at"), m)
      XCTAssertTrue(m.contains("Only the owner confirms, by typing yes when they run it at their own terminal (or with PERFLOOP_OWNER=1 on their own command line); there is no other way"), m)
    }
  }

  func testChampionSetIsRecordedLikeAnOwnerFlag() throws {
    let e = try store.add(try bench("base", ["CPU": "40"]))
    loop.owner = OwnerAuth(flags: ["champion set"], via: "env", command: "champion set")
    let c = try loop.setChampion(build: e.build.hash!, merged: true, scenario: "step", fixture: "crew17")
    // champion.json says who set it and how.
    XCTAssertEqual(c.setBy?.flag, "champion set"); XCTAssertEqual(c.setBy?.via, "env")
    XCTAssertEqual(store.champion()?.setBy, c.setBy)
    XCTAssertTrue(c.setBy!.effect.contains("every later verdict is judged against it"), c.setBy!.effect)
    // The baseline experiment, its ledger line, explain and status, as an owner flag's use.
    let base = try store.experiment(c.experiment)
    XCTAssertEqual(base.ownerFlags?.map(\.flag), ["champion set"]); XCTAssertEqual(base.forced, true)
    let l = try XCTUnwrap(store.ledger.entries().last)
    XCTAssertEqual(l.ownerFlags, ["champion set"]); XCTAssertEqual(l.ownerVia, "env"); XCTAssertEqual(l.by, "owner")
    XCTAssertTrue(l.text.contains("OWNER FLAG champion set (PERFLOOP_OWNER=1)"), l.text)
    XCTAssertTrue(loop.explain(base).contains("owner flag: champion set (PERFLOOP_OWNER=1, champion set"), loop.explain(base))
    XCTAssertTrue(loop.status().contains("OWNER FLAG champion set"), loop.status())
    // A champion that wins its place has no setBy.
    var o = Loop.NewOptions(hypothesis: "faster"); o.bench = try bench("fast", ["CPU": "8"])
    let won = try loop.full(try loop.new(o).id)
    loop.owner = nil
    _ = try loop.promote(won.id)
    XCTAssertNil(store.champion()?.setBy)
    // champion.json from before the field reads as before.
    var old = try XCTUnwrap(store.champion()); old.setBy = nil
    XCTAssertFalse(PLJSON.encode(old).contains("setBy"))
  }

  // MARK: champion merged: checked, not gated

  /// A champion built from `built` (the work branch's commit, in the app's checkout).
  func championFrom(_ built: String) throws {
    let e = try store.add(try bench("base", ["CPU": "40", "COMMIT": built]))
    try loop.setChampion(build: e.build.hash!, merged: false, scenario: "step", fixture: "crew17")
  }

  func refusal(_ f: () throws -> Any) -> String {
    var m = ""
    XCTAssertThrowsError(try f()) { e in XCTAssertEqual((e as? PLError)?.code, 6, "\(e)"); m = "\(e)" }
    return m
  }

  func testChampionMergedIsCheckedAgainstMainAndTheBuildCommit() throws {
    // Not a checkout: nothing can be checked.
    try championFrom("abc1234")
    XCTAssertTrue(refusal { try self.loop.markMerged(commit: "abc1234") }.contains("isn't a git checkout"))

    let built = try appRepo()
    try championFrom(built)
    let firstMain = try git("rev-parse", "main")
    // An unknown commit.
    XCTAssertTrue(refusal { try self.loop.markMerged(commit: "0123456789abcdef") }.contains("isn't a commit in this checkout"))
    XCTAssertTrue(refusal { try self.loop.markMerged(commit: "--all") }.contains("isn't a commit in this checkout"))
    // The build commit itself, still only on the PR's branch: not on main.
    var m = refusal { try self.loop.markMerged(commit: built) }
    XCTAssertTrue(m.contains("is not on main (checked: git merge-base --is-ancestor"), m); XCTAssertTrue(m.contains("git fetch origin"), m)
    // A commit on main that doesn't contain the build: not the PR's merge.
    m = refusal { try self.loop.markMerged(commit: firstMain) }
    XCTAssertTrue(m.contains("doesn't contain champion"), m); XCTAssertTrue(m.contains("build commit \(built.prefix(12))"), m)
    XCTAssertTrue(m.contains("If the PR was squash-merged or rebased, the champion's build commit is not on main and never will be, so champion merged keeps refusing it: ask the owner to set the champion from a build of main (perfloop champion set BUILD --merged)"), m)
    XCTAssertEqual(store.champion()?.merged, false, "a refusal changes nothing")
    XCTAssertFalse(store.ledger.entries().contains { $0.state == "merged" })

    // The PR merged: main has a commit that contains the build. Anyone may say so (no owner flag).
    let merge = try mergeWork()
    // origin/main is what counts when there is one: a stale one refuses until it is fetched.
    try git("update-ref", "refs/remotes/origin/main", firstMain)
    m = refusal { try self.loop.markMerged(commit: merge) }
    XCTAssertTrue(m.contains("is not on origin/main"), m)
    try git("update-ref", "refs/remotes/origin/main", merge)
    let (c, v) = try loop.markMerged(commit: merge)
    XCTAssertTrue(c.merged); XCTAssertEqual(c.mergedAncestor, merge); XCTAssertEqual(c.parents, [])
    XCTAssertEqual(v.checked, "checked: on origin/main, contains the build commit \(built.prefix(12))")
    let l = try XCTUnwrap(store.ledger.entries().last)
    XCTAssertEqual(l.state, "merged"); XCTAssertEqual(l.by, "agent"); XCTAssertNil(l.ownerFlags)
    XCTAssertEqual(l.note, "merged at \(merge) (\(v.checked))")
    // --main names another branch.
    try git("branch", "release", firstMain)
    XCTAssertTrue(refusal { try self.loop.markMerged(commit: merge, main: "release") }.contains("is not on release"))
    // The CLI takes --main (strict arguments), and nothing else new.
    XCTAssertNoThrow(try CLIArguments.check(["champion", "merged", "abc1234", "--main", "release"]))
    XCTAssertThrowsError(try CLIArguments.check(["champion", "merged", "abc1234", "--branch", "release"]))
    // A champion whose build records no commit can't be checked.
    try championFrom("")
    XCTAssertTrue(refusal { try self.loop.markMerged(commit: merge) }.contains("records no commit"))
  }

  /// A squash-merged (or rebased) PR: main has the change, not the build commit. champion merged refuses, every time, and
  /// says the way on is the owner's champion set on a build of main.
  func testASquashMergedChampionIsRefusedWithTheOwnersWayOn() throws {
    let built = try appRepo()
    try championFrom(built)
    try git("checkout", "-q", "main"); try git("commit", "-q", "--allow-empty", "-m", "the fix (squashed)")
    let squash = try git("rev-parse", "HEAD")
    var m = refusal { try self.loop.markMerged(commit: squash) }
    XCTAssertTrue(m.contains("doesn't contain champion"), m)
    XCTAssertTrue(m.hasSuffix(Loop.squashed), m)
    // The PR's branch deleted after the squash: the build commit isn't in the checkout at all. The same way on.
    try git("branch", "-q", "-D", "work"); try git("reflog", "expire", "--expire=now", "--all"); try git("gc", "-q", "--prune=now")
    m = refusal { try self.loop.markMerged(commit: squash) }
    XCTAssertTrue(m.contains("isn't in this checkout"), m); XCTAssertTrue(m.hasSuffix(Loop.squashed), m)
    XCTAssertEqual(store.champion()?.merged, false)
  }

  /// A dirty champion's uncommitted changes can't be checked against main: champion merged is the owner's for it,
  /// through the same gate as champion set, and the use is recorded like an owner flag's.
  func testADirtyChampionIsMarkedMergedOnlyByTheOwner() throws {
    let built = try appRepo()
    let e = try store.add(try bench("dirty", ["CPU": "40", "COMMIT": built, "DIRTY": "true"]))
    try loop.setChampion(build: e.build.hash!, merged: false, scenario: "step", fixture: "crew17")
    let merge = try mergeWork()
    // The agent (no owner): refused before anything is checked, with what to do instead.
    var m = refusal { try self.loop.markMerged(commit: merge) }
    XCTAssertTrue(m.contains("has uncommitted changes, and those can't be checked against main (only its commit can)"), m)
    XCTAssertTrue(m.contains("ask the owner to set a clean build of main as the champion (build main with nothing uncommitted, then perfloop champion set BUILD --merged)"), m)
    XCTAssertEqual(store.champion()?.merged, false); XCTAssertFalse(store.ledger.entries().contains { $0.state == "merged" })
    // The CLI's gate says the same, for an agent's shell (no terminal, no PERFLOOP_OWNER) …
    let c = try XCTUnwrap(store.champion())
    XCTAssertThrowsError(try gate().0.check(command: "champion merged", because: Loop.dirtyMerge(c))) { e in
      let m = "\(e)"
      XCTAssertTrue(m.hasPrefix("champion \(c.experiment)'s build [") && m.contains("marking it merged is the owner's say. Nothing shows the owner is running this"), m)
      XCTAssertTrue(m.contains("Instead: ask the owner to set a clean build of main as the champion"), m)
    }
    // … and asks at a terminal.
    let (yes, asked) = gate(terminal: true, answer: "yes")
    loop.owner = try yes.check(command: "champion merged", because: Loop.dirtyMerge(c))
    XCTAssertTrue(asked()[0].contains("has uncommitted changes"), asked()[0])
    // The owner confirmed: still checked against main, then recorded.
    m = refusal { try self.loop.markMerged(commit: "0123456789abcdef") }
    XCTAssertTrue(m.contains("isn't a commit in this checkout"), m); XCTAssertEqual(store.champion()?.merged, false)
    let (after, v) = try loop.markMerged(commit: merge)
    XCTAssertTrue(after.merged)
    XCTAssertTrue(v.checked.hasSuffix("the build was dirty: its uncommitted changes weren't checked (the owner's say)"), v.checked)
    XCTAssertEqual(after.mergedBy?.flag, "champion merged"); XCTAssertEqual(after.mergedBy?.via, "tty"); XCTAssertEqual(store.champion()?.mergedBy, after.mergedBy)
    XCTAssertTrue(after.mergedBy!.effect.contains("though its build was dirty"), after.mergedBy!.effect)
    let l = try XCTUnwrap(store.ledger.entries().last)
    XCTAssertEqual(l.state, "merged"); XCTAssertEqual(l.by, "owner"); XCTAssertEqual(l.ownerFlags, ["champion merged"]); XCTAssertEqual(l.ownerVia, "tty")
    XCTAssertTrue(l.text.contains("OWNER FLAG champion merged (confirmed at a terminal)"), l.text)
    let x = try store.experiment(after.experiment)
    XCTAssertEqual(x.ownerFlags?.last?.flag, "champion merged"); XCTAssertEqual(x.forced, true)
    XCTAssertTrue(loop.status().contains("OWNER FLAG champion merged"), loop.status())
    // A clean champion needs no owner: the existing check is all (testChampionMergedIsCheckedAgainstMainAndTheBuildCommit).
    XCTAssertNil(try championFromClean(built).mergedBy)
  }

  func championFromClean(_ built: String) throws -> Champion {
    loop.owner = nil
    try championFrom(built)
    return try loop.markMerged(commit: try git("rev-parse", "main")).champion
  }

  func testNoMCPToolSetsOrMergesTheChampion() throws {
    let s = MCPServer(cli: "/bin/echo", jobsDir: tmp.appendingPathComponent("jobs"))
    let names = s.tools.map(\.name)
    for n in names { XCTAssertFalse(n.contains("set") || n.contains("merge") || n.contains("replay"), n) }
    let champion = try XCTUnwrap(s.tools.first { $0.name == "champion" })
    XCTAssertEqual(try champion.args([:]), ["champion"])
    XCTAssertEqual(try champion.args(["set": .string("x"), "merged": .string("abc")]), ["champion"], "arguments it doesn't declare are ignored")
  }
}

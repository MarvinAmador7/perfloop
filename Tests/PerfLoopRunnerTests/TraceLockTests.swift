import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// F4: a profile's trace is deleted by the runner, whatever the adapter did, and what is printed is what is on disk;
/// `store gc` and `doctor` find traces left behind. F9: the local runner and `perfloop lock` hold the window lock.
final class TraceLockTests: FakeBenchCase {
  override func tearDownWithError() throws {
    WindowLock.releaseAll(); unsetenv(WindowLock.heldVariable)
    for k in ["FAKE_TRACE_STUCK", "FAKE_PROFILE_FAIL"] { unsetenv(k) }
    // A stuck trace's folder was made read-only: give the temp dir back its rights so it can go.
    if let en = FileManager.default.enumerator(atPath: tmp.path) {
      for case let p as String in en where p.hasSuffix(".trace") { chmod(tmp.appendingPathComponent(p).path, 0o755) }
    }
    try super.tearDownWithError()
  }

  func traces() -> [String] { Traces.find(under: store.root).map(\.path) }

  // MARK: F4

  /// The fake adapter implements `profile` itself, leaves its trace and never says so (as capcomd's did): the runner
  /// deletes it, the document and its JSON say `traceKept: false`, and the text says "deleted".
  func testTheRunnerDeletesATraceTheAdapterLeft() throws {
    try baseline()
    let r = try loop.profile("champion")
    XCTAssertEqual(traces(), [], "no trace left in the store")
    XCTAssertEqual(r.doc.traceKept, false)
    XCTAssertTrue(r.doc.text.contains("\ntrace: deleted\n"), r.doc.text)
    let disk = try PLJSON.read(JSONValue.self, path: r.path)
    XCTAssertEqual(disk["traceKept"]?.bool, false)
    XCTAssertEqual(disk["adapterField"], .number(1), "the JSON is patched, not rewritten: the adapter's own fields stay")
    XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: r.path).deletingLastPathComponent().appendingPathComponent(Traces.marker).path))
  }

  func testKeepTraceKeepsItAndSaysWhere() throws {
    try baseline()
    let r = try loop.profile("champion", keepTrace: true)
    let left = traces()
    XCTAssertEqual(left.count, 1)
    XCTAssertEqual(r.doc.traceKept, true); XCTAssertEqual(r.doc.trace, left.first)
    XCTAssertTrue(r.doc.text.contains("trace: KEPT at \(left[0]): it holds the recorded process's environment"), r.doc.text)
    XCTAssertEqual(try PLJSON.read(JSONValue.self, path: r.path)["traceKept"]?.bool, true)
    // Kept on purpose: gc leaves it unless --traces, doctor warns.
    XCTAssertEqual(store.gcTraces(all: false).kept.map(\.path), left)
    XCTAssertEqual(traces(), left)
    XCTAssertEqual(doctorTraces(), .warn)
    XCTAssertEqual(store.gcTraces(all: true).removed.map(\.path), left)
    XCTAssertEqual(traces(), [])
    XCTAssertEqual(doctorTraces(), .ok)
  }

  /// A kept trace holds the environment the recorded process ran with: the adapter is started with an allowlist and
  /// the names its manifest declares (`profileEnv`), so no token reaches it, declared or not.
  func testAKeptTraceCarriesNoSecrets() throws {
    try baseline()
    let secrets = ["GITHUB_TOKEN": "ghp_fake", "OPENAI_API_KEY": "sk-fake", "PERFLOOP_OWNER": "1", "PERFLOOP_VM_PASSWORD": "admin", "SSH_AUTH_SOCK": "/tmp/agent.sock",
                   "AWS_SECRET_ACCESS_KEY": "fake", "FAKE_API_TOKEN": "declared-but-secret", "SOME_TOOL_SETTING": "not declared"]
    for (k, v) in secrets { setenv(k, v, 1) }
    setenv("LC_ALL", "en_US.UTF-8", 1); setenv("PERFLOOP_KNOBS", "reel.slide=clip", 1)
    defer { for k in Array(secrets.keys) + ["LC_ALL", "PERFLOOP_KNOBS"] { unsetenv(k) } }
    let r = try loop.profile("champion", keepTrace: true)
    let env = try String(contentsOfFile: try XCTUnwrap(r.doc.trace) + "/environment", encoding: .utf8)
    let names = Set(env.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
    for k in secrets.keys { XCTAssertFalse(names.contains(k), "\(k) reached the trace") }
    XCTAssertFalse(env.contains("ghp_fake") || env.contains("sk-fake"))
    // What the app needs, and what the adapter declares, are there.
    for k in ["PATH", "HOME", "LC_ALL", "PERFLOOP_KNOBS", "FAKE_LOG"] { XCTAssertTrue(names.contains(k), "\(k) missing: \(names.sorted())") }
    // Nothing else, but what the shell running the fake adapter sets itself (PWD, SHLVL, _).
    let extra = names.filter { !$0.hasPrefix("LC_") }.subtracting(TraceEnv.system.union(TraceEnv.perfloop).union(["FAKE_LOG", "PWD", "SHLVL", "_", "OLDPWD"]))
    XCTAssertEqual(extra, [], "\(names.sorted())")
    XCTAssertEqual(doctorTraces(), .warn, "a kept trace stays a warning")
  }

  func testTheTraceEnvironmentAllowlist() {
    let env = ["PATH": "/usr/bin", "HOME": "/h", "TMPDIR": "/t", "LANG": "C", "LC_CTYPE": "UTF-8", "DEVELOPER_DIR": "/x", "PERFLOOP_KNOBS": "a=b",
               "PERFLOOP_OWNER": "1", "PERFLOOP_VM_PASSWORD": "p", "PERFLOOP_SSH": "/s", "GH_TOKEN": "t", "ANTHROPIC_API_KEY": "k", "NPM_CONFIG_AUTH": "a",
               "MY_APP_MODE": "demo", "MY_APP_SESSION": "s", "TERM_SESSION_ID": "x"]
    XCTAssertEqual(Set(TraceEnv.scrub(env).keys), ["PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "DEVELOPER_DIR", "PERFLOOP_KNOBS"])
    XCTAssertEqual(Set(TraceEnv.scrub(env, declared: ["MY_APP_MODE", "MY_APP_SESSION", "PERFLOOP_OWNER"]).keys),
                   ["PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "DEVELOPER_DIR", "PERFLOOP_KNOBS", "MY_APP_MODE"], "declared, but secret-like: dropped")
  }

  func testAFailedDeleteIsReportedNotHidden() throws {
    try XCTSkipIf(getuid() == 0, "root deletes a read-only folder's contents anyway")
    try baseline()
    setenv("FAKE_TRACE_STUCK", "1", 1)
    let r = try loop.profile("champion")
    XCTAssertEqual(r.doc.traceKept, true)
    XCTAssertTrue(r.doc.text.contains("trace: KEPT at "), r.doc.text)
    XCTAssertTrue(r.doc.notes.contains { $0.hasPrefix("couldn't delete ") && $0.contains("stuck.trace") }, "\(r.doc.notes)")
    XCTAssertEqual(traces().map { URL(fileURLWithPath: $0).lastPathComponent }, ["stuck.trace"], "the deletable one went")
    XCTAssertEqual(doctorTraces(), .fail, "a trace nobody kept on purpose fails doctor")
  }

  func testATraceIsDeletedWhenTheProfileFails() throws {
    try baseline()
    setenv("FAKE_PROFILE_FAIL", "1", 1)
    XCTAssertThrowsError(try loop.profile("champion")) { XCTAssertTrue("\($0)".contains("exited 2"), "\($0)") }
    XCTAssertEqual(traces(), [])
  }

  /// Traces left by anything else: gc deletes them (not one being recorded), doctor fails on them.
  func testGcAndDoctorFindStrayTraces() throws {
    let a = store.root.appendingPathComponent("profiles/x/a.trace"), b = store.root.appendingPathComponent("exp/0001/b.trace")
    let busy = store.root.appendingPathComponent("profiles/y/c.trace")
    for t in [a, b, busy] {
      try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
      try "FAKE_TOKEN=secret".write(to: t.appendingPathComponent("env"), atomically: true, encoding: .utf8)
    }
    // y is being recorded: its marker names a live process.
    try String(getppid()).write(to: busy.deletingLastPathComponent().appendingPathComponent(Traces.marker), atomically: true, encoding: .utf8)
    XCTAssertEqual(doctorTraces(), .fail)
    let g = store.gcTraces(all: true)
    XCTAssertEqual(Set(g.removed.map(\.path)), Set([a.path, b.path]))
    XCTAssertEqual(g.recording.map(\.path), [busy.path])
    XCTAssertEqual(traces(), [busy.path])
    XCTAssertEqual(doctorTraces(), .ok, "one being recorded is no failure")
  }

  func doctorTraces() -> Doctor.Status? {
    var p = MachineProbe()
    p.idle = ScriptedIdleSource { IdleReading(idle: 600, frontmost: "Finder", locked: false) }
    p.freeBytes = { _ in 100_000_000_000 }; p.gitTop = { _ in nil }; p.windowLock = { _ in .free }
    var d = Doctor(); d.checkMachine(store: store.root, env: [:], probe: p)
    return d.lines.first { $0.check == "traces" }?.status
  }

  // MARK: F9

  func testDoctorSaysWhoHoldsTheWindowLock() {
    func line(_ s: WindowLock.State, env: [String: String] = [:]) -> Doctor.Line? {
      var p = MachineProbe()
      p.idle = ScriptedIdleSource { IdleReading(idle: 600, frontmost: "Finder", locked: false) }
      p.freeBytes = { _ in 100_000_000_000 }; p.gitTop = { _ in nil }; p.traces = { _ in [] }; p.windowLock = { _ in s }
      var d = Doctor(); d.checkMachine(store: store.root, env: env, probe: p)
      return d.lines.first { $0.check == "window lock" }
    }
    XCTAssertEqual(line(.free)?.status, .ok)
    let h = WindowLock.Holder(pid: 71104, command: "perfloop exp screen 0003", label: "palette", since: Clock.now())
    XCTAssertTrue(line(.held(h))?.detail.contains("held by pid 71104 (perfloop exp screen 0003) \"palette\"") == true)
    XCTAssertEqual(line(.held(nil))?.status, .warn)
    XCTAssertEqual(line(.free, env: ["PERFLOOP_LOCK": "off"])?.status, .warn)
  }

  /// The local runner waits for the window lock, says who holds it, and its rep runs inside the hold.
  func testTheLocalRunnerHoldsTheWindowLockAroundARep() throws {
    let lock = tmp.appendingPathComponent("window.lock").path
    try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
    try PLJSON.encode(WindowLock.Holder(pid: getppid(), command: "deskbench ab", label: "sidebar", since: Clock.now())).write(toFile: lock + "/owner", atomically: true, encoding: .utf8)
    let r = LocalRunner(); r.lockDir = lock; r.lockPoll = 0.05
    var waits: [String] = []
    r.onWait = { waits.append($0) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? FileManager.default.removeItem(atPath: lock) }
    let o = try r.run("/bin/sh", ["-c", "echo \"$PERFLOOP_LOCK_HELD\"; cat \"$PERFLOOP_LOCK_HELD/owner\""], env: [:], workDir: tmp.appendingPathComponent("w"))
    XCTAssertTrue(waits.first?.contains("is held by pid \(getppid()) (deskbench ab) \"sidebar\"") == true, "\(waits)")
    XCTAssertTrue(o.stdout.hasPrefix(lock + "\n"), o.stdout)
    XCTAssertTrue(o.stdout.contains("\"pid\" : \(getpid())") || o.stdout.contains("\"pid\":\(getpid())"), o.stdout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock), "released after the rep")
  }

  /// `perfloop lock -- CMD`: CMD runs inside the hold (and knows it), its status comes back, the lock is released.
  func testLockCommandHoldsTheLockAroundACommand() throws {
    let lock = tmp.appendingPathComponent("window.lock").path
    let status = try LockCommand.run(["sh", "-c", "test \"$PERFLOOP_LOCK_HELD\" = \"\(lock)\" && grep -q '\"label\" *: *\"needsreel\"' \"$PERFLOOP_LOCK_HELD/owner\" && exit 3"],
                                     path: lock, label: "needsreel", log: { _ in })
    XCTAssertEqual(status, 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
    XCTAssertEqual(try LockCommand.run(["sh", "-c", "kill -TERM $$"], path: lock, label: nil, log: { _ in }), 128 + SIGTERM)
  }
}

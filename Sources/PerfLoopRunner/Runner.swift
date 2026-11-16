import Foundation
import PerfLoopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the adapter's window-opening verbs (`ab`, `run`) run (CAPABILITIES.md C10, SPEC §4.2). Headless verbs
/// (`list`, `describe`, `snapdiff`, `diff`) always run here, on the store's own copy.
///
/// The loop measures a pair as: `prepare` both builds, `run` the adapter with paths under the store root (the runner
/// maps them to its own), `fetch` what the run wrote under the pair's directory. Every pair records `identity()`.
public protocol Runner: AnyObject {
  /// "local", "ssh://host", "vm:tart/name": the name results carry.
  var name: String { get }
  /// Progress and why the runner waited (the queue keeps the latter).
  var log: (String) -> Void { get set }
  /// Called with each new reason the runner waits for its machine to be free (one line per change, not per poll).
  var onWait: (String) -> Void { get set }
  /// Don't start a rep after this (`queue run --until`): `run` throws `RunnerStop.deadline` instead.
  var deadline: Date? { get set }
  /// The runner and its machine (`machine.model`), recorded on every pair. Connects, for a remote runner.
  func identity() throws -> RunnerIdentity
  /// Makes a store build runnable there and returns its executable's path on the runner. Idempotent: a build the
  /// runner already has (by content hash) isn't copied again.
  @discardableResult func prepare(_ build: Store.Entry) throws -> String
  /// One adapter call (a rep or an interleaved pair). Arguments and environment name local paths; the result
  /// (`--out`) and artifacts land under `workDir`, on the runner. Exit status 7 (SCHEMAS.md): interrupted, redo it.
  func run(_ exe: String, _ args: [String], env: [String: String], workDir: URL) throws -> Adapter.Output
  /// Brings what `run` wrote under `workDir` back into the store, paths rewritten to the local ones. Local: nothing.
  func fetch(_ workDir: URL) throws
  /// Ends connections and the like.
  func close()
}

/// Why a runner stopped before a rep: the queue keeps the item and resumes it next time.
public enum RunnerStop: Error, CustomStringConvertible {
  case deadline(Date)
  case signal(Int32)
  /// `--no-wait`: the screen was locked, so no rep started.
  case locked
  /// `--require-quiet`: the machine stayed busy past the quiet timeout, so no rep started.
  case notQuiet(waited: Double, why: String)
  public var description: String {
    switch self {
    case .deadline(let d): "reached --until \(Clock.iso(d)) before the next rep"
    case .signal(let s): "stopped by signal \(s)"
    case .locked: "the screen is locked: a window behind the lock screen is never active, so every rep would be untrusted; no rep started (--no-wait). Unlock it and run the same command again (without --no-wait the runner waits for the unlock); finished pairs are kept"
    case .notQuiet(let w, let why): "the machine wasn't quiet after \(Int(w)) s (\(why)); no rep started (--require-quiet). Run the same command again once that work is done (finished pairs are kept), or leave out --require-quiet to run and record the reps as not quiet"
    }
  }
}

/// The exit status a runner gives an aborted rep (SCHEMAS.md: 7 interrupted).
public let interruptedStatus: Int32 = 7

public enum Runners {
  /// A runner from its command-line form. `options` are the queue's and `exp`'s flags.
  public static func make(_ spec: String, store: Store, options o: RunnerOptions = RunnerOptions()) throws -> Runner {
    guard let s = RunnerSpec(spec) else { throw PLError.usage("unknown runner '\(spec)': local, ssh://[user@]host[:port][/store-dir] or vm:tart/NAME") }
    switch s {
    case .local:
      let r = LocalRunner()
      if !o.force { r.gate = IdleGate(threshold: o.idle ?? 120, busyApps: o.busyApps ?? IdleGate.defaultBusyApps) }
      if let f = o.idleFrom { let src = FileIdleSource(path: f); r.idle = src; r.load = src }
      r.lockDir = o.lock
      r.waitWhileLocked = !o.noWait
      r.quiet = o.quiet
      return r
    case .ssh(let user, let host, let port, let root):
      let r = SSHRunner(spec: s, user: user, host: host, port: port, root: root, store: store)
      r.acceptNewHostKey = o.acceptNewHostKey
      r.remoteEnv = o.remoteEnv
      if let l = o.launch { guard let m = SSHRunner.Launch(rawValue: l) else { throw PLError.usage("--launch gui|direct") }; r.launch = m }
      if let i = o.idle, !o.force { r.gate = IdleGate(threshold: i, busyApps: o.busyApps ?? IdleGate.defaultBusyApps) }
      return r
    case .vm(let tool, let name): return try VMRunner(tool: tool, name: name, store: store)
    }
  }
}

public struct RunnerOptions {
  /// Idle threshold, seconds (local: 120 unless `force`; ssh: gated only when given).
  public var idle: Double?
  /// No idle gate: a bench nobody minds.
  public var force = false
  public var busyApps: [String]?
  /// The testing hook: read the idle time from this file (`idle=… frontmost=… locked=…`, or seconds) instead of IOKit.
  public var idleFrom: String?
  public var acceptNewHostKey = false
  public var remoteEnv: [String: String] = [:]
  public var launch: String?
  /// Local: a mkdir lock taken around each rep once the gate says go (window runs on one Mac take turns).
  public var lock: String?
  /// Local: refuse (`RunnerStop.locked`) instead of waiting while the screen is locked (`--no-wait`).
  public var noWait = false
  /// Local: the quiet gate (`--max-load`, `--quiet-timeout`, `--require-quiet`); on by default, nil turns it off.
  public var quiet: QuietGate? = QuietGate()
  public init() {}
}

// MARK: local

/// This Mac. Ungated (`--force`, and `exp screen/full` without `--idle`), or idle-gated: a rep starts only once nobody
/// has touched the Mac for the threshold, and is aborted (killed with its children, status 7) when input arrives.
/// Either way, no rep starts while the screen is locked (a window behind the lock screen never draws: the rep would be
/// untrusted and its frame metrics empty): the runner waits for the unlock, or with `--no-wait` refuses; a rep during
/// which the screen locks is aborted and redone. And with the quiet gate (on by default) a rep waits, up to its
/// timeout, for the machine to be quiet, and records what it saw on the rep (`Adapter.Output.machine`).
public final class LocalRunner: Runner {
  public var gate: IdleGate?
  public var idle: IdleSource = HIDIdleSource()
  /// false (`--no-wait`): a locked screen stops the run (`RunnerStop.locked`) instead of being waited out.
  public var waitWhileLocked = true
  /// Seconds between screen-lock readings while waiting for the unlock.
  public var lockPoll = 5.0
  /// The quiet gate: nil, no load check (the library's default; the CLI always sets one).
  public var quiet: QuietGate?
  public var load: LoadSource = HostLoadSource()
  /// Seconds between load readings while waiting for quiet (each reading also samples for half a second).
  public var quietPoll = 0.5
  /// A wait for quiet timed out since the last quiet start: later waits are short (QuietGate.retryTimeout).
  var quietTimedOut = false
  public var deadline: Date?
  /// Seconds between idle readings, waiting and during a rep.
  public var poll = 0.5
  /// A waiting runner repeats its reason this often even when it hasn't changed (the queue's log stays alive).
  public var waitLogEvery: Double = 600
  public var log: (String) -> Void = { _ in }
  public var onWait: (String) -> Void = { _ in }
  /// A mkdir lock held only while a rep runs (`--lock DIR`, as `sweep --lock`): taken after the idle gate says go,
  /// so a runner waiting for the owner to leave never blocks another bench window on this Mac.
  public var lockDir: String?
  public init() {}

  public var name: String { "local" }
  var cachedIdentity: RunnerIdentity?
  public func identity() throws -> RunnerIdentity {
    if let c = cachedIdentity { return c }
    let i = RunnerIdentity(runner: name, model: MachineModel.local(), host: MachineModel.shortHost(), os: ProcessInfo.processInfo.operatingSystemVersionString)
    cachedIdentity = i
    return i
  }
  public func prepare(_ build: Store.Entry) throws -> String { build.executable }
  public func fetch(_ workDir: URL) throws {}
  public func close() {}

  public func run(_ exe: String, _ args: [String], env: [String: String], workDir: URL) throws -> Adapter.Output {
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    var start: IdleReading, held: (() -> Void)?, machine: MachineState?
    while true {
      try waitForUnlock()
      if let gate { start = try waitForIdle(gate) } else { try checkDeadline(); start = idle.read() }
      held = try takeLock()
      // After the window lock: another bench's window running here is a wait for the lock, not noise to time out on.
      if let q = quiet { machine = try waitForQuiet(q) }
      guard held != nil || (machine?.waitedS ?? 0) > 0 else { break }
      // The waits for the lock and for quiet may have taken a while: still unlocked and idle, or give the lock back and
      // wait again.
      let now = idle.read()
      if now.locked != true, gate?.wait(now) == nil { start = now; break }
      held?(); held = nil
    }
    defer { held?() }
    let child = try Child(exe, args, env: env)
    var why: String?
    while child.running {
      Thread.sleep(forTimeInterval: gate == nil ? max(poll, 1) : poll)
      guard child.running else { break }
      if let gate {
        let now = idle.read()
        if let w = gate.interrupted(previous: start, now: now) { why = w; break }
        if now.idle != nil { start = now }
      } else if readLockedNow(), start.locked != true {
        // Ungated, only the lock is watched: the rest of the rep would draw nothing.
        why = "the screen locked during the rep"; break
      }
    }
    if let w = why {
      log("interrupted: \(w); the rep is killed and redone")
      onWait("interrupted: \(w)")
      child.kill()
      return Adapter.Output(status: interruptedStatus, stdout: child.finish().stdout, machine: machine)
    }
    var o = child.finish()
    o.machine = machine
    return o
  }

  func readLockedNow() -> Bool { idle.readLocked() == true }

  /// Blocks while the screen is locked (whether or not the runner is idle-gated), or with `--no-wait` stops the run.
  func waitForUnlock() throws {
    var said = false
    while readLockedNow() {
      guard waitWhileLocked else { throw RunnerStop.locked }
      if !said {
        let t = "waiting: the screen is locked: a window behind the lock screen is never active (unlock it; --no-wait stops instead of waiting)"
        log(t); onWait(t); said = true
      }
      try checkDeadline()
      Thread.sleep(forTimeInterval: lockPoll)
    }
    if said { log("the screen is unlocked: starting the rep") }
  }

  /// Waits, up to the gate's timeout, for the machine to be quiet; returns what the rep starts on (nil: the load
  /// can't be read here). A rep that starts busy says so (log, `onWait`, and `quiet: false` on the rep); with
  /// `--require-quiet` the run stops instead.
  func waitForQuiet(_ q: QuietGate) throws -> MachineState? {
    let t0 = Date(), limit = quietTimedOut ? min(q.timeout, q.retryTimeout) : q.timeout
    var said = false
    while true {
      let r = load.readLoad()
      if r.unknown { return nil }
      let waited = Date().timeIntervalSince(t0)
      guard let why = q.busy(r) else {
        if said { log("quiet after \(Int(waited)) s: starting the rep") }
        quietTimedOut = false
        return q.state(r, waited: waited)
      }
      if waited >= limit {
        if q.require { throw RunnerStop.notQuiet(waited: waited, why: why) }
        let t = "not quiet after \(Int(waited)) s (\(why)): the rep runs anyway and is recorded as not quiet (quiet: false)"
        log(t); onWait(t)
        quietTimedOut = true
        return q.state(r, waited: waited)
      }
      if !said {
        let t = "waiting up to \(Int(limit)) s for a quiet machine: \(why) (--max-load PCT, --quiet-timeout S, --require-quiet)"
        log(t); onWait(t); said = true
      }
      try checkDeadline()
      Thread.sleep(forTimeInterval: quietPoll)
    }
  }

  func checkDeadline() throws { if let d = deadline, Date() >= d { throw RunnerStop.deadline(d) } }

  /// Takes `lockDir` (mkdir; `owner` says who), returning its release; nil without a lock.
  func takeLock() throws -> (() -> Void)? {
    guard let l = lockDir else { return nil }
    var said = false
    while (try? FileManager.default.createDirectory(atPath: l, withIntermediateDirectories: false)) == nil {
      try checkDeadline()
      if !said { let who = (try? String(contentsOfFile: l + "/owner", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"; let t = "waiting: the window lock \(l) is held (\(who))"; log(t); onWait(t); said = true }
      Thread.sleep(forTimeInterval: 2)
    }
    let who = ProcessInfo.processInfo.environment["PERFLOOP_LOCK_OWNER"].map { $0 + " " } ?? ""
    try? "\(who)perfloop pid \(ProcessInfo.processInfo.processIdentifier)".write(toFile: l + "/owner", atomically: true, encoding: .utf8)
    return { try? FileManager.default.removeItem(atPath: l) }
  }

  /// Blocks until the gate says go; returns the reading it went on.
  func waitForIdle(_ gate: IdleGate) throws -> IdleReading {
    var lastKind: String?, lastAt = Date.distantPast
    while true {
      let r = idle.read()
      guard let w = gate.wait(r) else {
        try checkDeadline()
        if lastKind != nil { log("idle \(Int(r.idle ?? 0)) s ≥ \(Int(gate.threshold)) s: starting the rep") }
        return r
      }
      if w.kind != lastKind || Date().timeIntervalSince(lastAt) >= waitLogEvery {
        let t = "waiting: " + w.text(threshold: gate.threshold)
        log(t); onWait(t)
        lastKind = w.kind; lastAt = Date()
      }
      try checkDeadline()
      // Sleep at most until the threshold could be met, at least one poll.
      if case .recent(let i, _) = w { Thread.sleep(forTimeInterval: max(poll, min(gate.threshold - i, 30))) } else { Thread.sleep(forTimeInterval: max(poll, 5)) }
    }
  }
}

// MARK: processes

/// A child the runner can watch while it runs and kill with its descendants (an adapter's `ab` starts one process per
/// side: killing only the parent would leave a window open).
public final class Child {
  let p = Process()
  private var data = Data()
  private let done = DispatchSemaphore(value: 0)
  /// The children being watched, for a signal handler to kill (`queue run` on ^C).
  static var live: [Int32: Child] = [:]
  static let liveLock = NSLock()

  public init(_ exe: String, _ args: [String], env: [String: String] = [:], cwd: String? = nil, stdin: FileHandle? = nil, stderr: FileHandle = .standardError) throws {
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    var e = ProcessInfo.processInfo.environment; for (k, v) in env { e[k] = v }; p.environment = e
    if let c = cwd { p.currentDirectoryURL = URL(fileURLWithPath: c) }
    let out = Pipe(); p.standardOutput = out; p.standardError = stderr
    p.standardInput = stdin ?? FileHandle.nullDevice
    do { try p.run() } catch { throw PLError.harness("couldn't start \(exe): \(error)") }
    Child.liveLock.lock(); Child.live[p.processIdentifier] = self; Child.liveLock.unlock()
    DispatchQueue.global().async { [self] in data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
  }

  public var running: Bool { p.isRunning }
  public var pid: Int32 { p.processIdentifier }

  /// Waits for the exit and the whole stdout.
  public func finish() -> Adapter.Output {
    p.waitUntilExit(); done.wait()
    Child.liveLock.lock(); Child.live[p.processIdentifier] = nil; Child.liveLock.unlock()
    return Adapter.Output(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
  }

  /// SIGTERM to the child and every descendant, SIGKILL to what is left after `grace` seconds (ProcessTree.kill).
  public func kill(grace: Double = 3) { ProcessTree.kill(p.processIdentifier, grace: grace) }

  /// Kills every watched child's tree (a signal handler's last act).
  public static func killAll() {
    liveLock.lock(); let pids = Array(live.keys); liveLock.unlock()
    for pid in pids { ProcessTree.kill(pid, grace: 2) }
  }
}

public enum ProcessTree {
  /// `pid` and its descendants, parents first (from `ps -A -o pid=,ppid=`).
  public static func tree(_ pid: Int32) -> [Int32] {
    guard let o = try? Adapter.spawn("/bin/ps", ["-A", "-o", "pid=", "-o", "ppid="], quiet: true) else { return [pid] }
    var kids: [Int32: [Int32]] = [:]
    for line in o.stdout.split(separator: "\n") {
      let f = line.split(separator: " ", omittingEmptySubsequences: true)
      if f.count == 2, let c = Int32(f[0]), let p = Int32(f[1]) { kids[p, default: []].append(c) }
    }
    var out = [pid], i = 0
    while i < out.count { out += kids[out[i]] ?? []; i += 1 }
    return out
  }

  /// SIGTERM to `pid` and every descendant, SIGKILL to what is left after `grace` seconds. The tree is frozen first
  /// (SIGSTOP, then read again until no new process appears), so a child forked while the kill runs isn't missed and
  /// orphaned (a shell about to start `sleep` was, in the MCP server's tests).
  public static func kill(_ pid: Int32, grace: Double = 3) {
    var all: [Int32] = []
    for _ in 0..<10 {
      let now = tree(pid).filter { !all.contains($0) }
      if now.isEmpty { break }
      for p in now { _ = sysKill(p, SIGSTOP) }
      all += now
    }
    for p in all { _ = sysKill(p, SIGTERM) }
    for p in all { _ = sysKill(p, SIGCONT) }
    let until = Date().addingTimeInterval(grace)
    while Date() < until, all.contains(where: { sysKill($0, 0) == 0 && !zombie($0) }) { Thread.sleep(forTimeInterval: 0.1) }
    for p in all where sysKill(p, 0) == 0 { _ = sysKill(p, SIGKILL) }
  }

  static func sysKill(_ pid: Int32, _ sig: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.kill(pid, sig)
    #else
    Glibc.kill(pid, sig)
    #endif
  }
  static func zombie(_ pid: Int32) -> Bool {
    guard let o = try? Adapter.spawn("/bin/ps", ["-o", "stat=", "-p", String(pid)], quiet: true) else { return false }
    return o.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
  }
}

/// `machine.model` and the host name of this Mac (or Linux box).
public enum MachineModel {
  public static func local() -> String? {
    #if canImport(Darwin)
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
    #else
    return (try? String(contentsOfFile: "/sys/devices/virtual/dmi/id/product_name", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    #endif
  }
  public static func shortHost() -> String {
    let h = ProcessInfo.processInfo.hostName
    return String(h.split(separator: ".").first ?? Substring(h))
  }
}

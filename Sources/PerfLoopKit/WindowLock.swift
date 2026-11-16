import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The window lock: one bench window at a time on this Mac (AGENTS.md "The machine"). A directory made with mkdir
/// (atomic, so a shell's `until mkdir "$L"; do sleep 2; done` can take turns with it), holding `owner`: who holds it, as
/// JSON `{"pid": 123, "command": "perfloop exp screen 0003", "label": "…", "since": "<ISO 8601>"}`.
///
/// On by default at `defaultPath` (`PERFLOOP_LOCK` moves it; `off` turns it off): the perfloop CLI's window verbs and its
/// MCP server's jobs hold it around each rep, a PerfLoopHost bench's `run`, `profile` and `record-gesture` hold it for
/// their whole run, and `perfloop lock -- CMD` holds it around anything else that opens a window.
///
/// A holder exports `PERFLOOP_LOCK_HELD` (the lock's path) to its children. A process that finds it naming a lock a live
/// process holds is inside that hold and takes no lock of its own (a bench run by `perfloop exp screen`, or `perfloop exp
/// screen` run by `perfloop lock --`), so a hold never waits for itself. A lock whose holder is gone (its pid dead, or
/// reused by a process that started after the lock was taken) is broken by the next taker. A lock with no owner file (made
/// by hand) is never broken: the waiter says so.
public final class WindowLock {
  public static let pathVariable = "PERFLOOP_LOCK"
  public static let heldVariable = "PERFLOOP_LOCK_HELD"
  /// A label for the holder (an agent's name), written to the owner file.
  public static let labelVariable = "PERFLOOP_LOCK_OWNER"

  /// Who holds a lock, from its owner file.
  public struct Holder: Codable, Equatable, Sendable {
    public var pid: Int32?
    public var command: String?
    public var label: String?
    public var since: String?
    /// The owner file as written when it isn't this JSON (a hand-made lock, or an older perfloop's `perfloop pid N`).
    public var raw: String?
    public init(pid: Int32? = nil, command: String? = nil, label: String? = nil, since: String? = nil, raw: String? = nil) {
      self.pid = pid; self.command = command; self.label = label; self.since = since; self.raw = raw
    }

    /// `pid 71104 (perfloop exp screen 0003) "palette", since 2026-11-16T10:01:03Z (3 min ago)`.
    public func line(now: Date = Date()) -> String {
      if pid == nil || command == nil, let r = raw { return r + (pid == nil ? " (no pid in its owner file: made by hand?)" : "") }
      var s = pid.map { "pid \($0)" } ?? "?"
      if let c = command { s += " (\(c))" }
      if let l = label { s += " \"\(l)\"" }
      if let t = since {
        s += ", since \(t)"
        if let d = Clock.date(t) { s += " (\(WindowLock.age(now.timeIntervalSince(d))) ago)" }
      }
      return s
    }
  }

  public enum State: Equatable {
    case free
    /// Held by a live process, or by one we can't check (no owner file, or no pid in it: nil / a holder without pid).
    case held(Holder?)
    /// Held by a process that is gone: the next taker breaks it.
    case stale(Holder)
  }

  public struct Failure: Error, CustomStringConvertible {
    public var description: String
  }

  /// `$PERFLOOP_LOCK`, else `/tmp/perfloop-window-<uid>.lock` (not `$TMPDIR`: agents' sandboxes give each their own
  /// TMPDIR, and the point is that they all meet here); nil when `PERFLOOP_LOCK` is `off`.
  public static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    if let p = env[pathVariable], !p.isEmpty { return ["off", "none", "0"].contains(p.lowercased()) ? nil : p }
    return "/tmp/perfloop-window-\(getuid()).lock"
  }

  /// The owner file of the lock at `path`; nil when there is none (a free lock, or one made by hand).
  public static func holder(at path: String) -> Holder? {
    guard let t = try? String(contentsOfFile: path + "/owner", encoding: .utf8) else { return nil }
    if let h = try? PLJSON.decode(Holder.self, from: Data(t.utf8)), h.pid != nil { return h }
    let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
    var h = Holder(raw: s.isEmpty ? "an empty owner file" : s)
    if let r = s.range(of: #"pid [0-9]+"#, options: .regularExpression) { h.pid = Int32(s[r].dropFirst(4)) }
    return h
  }

  public static func state(at path: String) -> State {
    var dir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &dir) else { return .free }
    guard let h = holder(at: path) else { return .held(nil) }
    return gone(h) ? .stale(h) : .held(h)
  }

  /// The holder's process is gone: its pid is dead, or now names a process started after the lock was taken.
  public static func gone(_ h: Holder) -> Bool {
    guard let p = h.pid else { return false }
    if !alive(p) { return true }
    if let s = h.since.flatMap(Clock.date), let t = startTime(p), t > s.addingTimeInterval(1) { return true }
    return false
  }

  public static func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

  /// When a process started (Darwin: sysctl KERN_PROC_PID); nil where unknown.
  static func startTime(_ pid: Int32) -> Date? {
    #if canImport(Darwin)
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    #else
    return nil
    #endif
  }

  /// "40 s", "3 min", "2 h 5 min".
  static func age(_ s: Double) -> String {
    let x = Int(max(0, s))
    if x < 60 { return "\(x) s" }
    if x < 3600 { return "\(x / 60) min" }
    return "\(x / 3600) h \(x % 3600 / 60) min"
  }

  /// This process's command line as the owner file shows it: the executable's name and its arguments, cut at 200
  /// characters.
  public static func ownCommand(_ argv: [String] = CommandLine.arguments) -> String {
    let s = ([argv.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"] + argv.dropFirst()).joined(separator: " ")
    return s.count > 200 ? String(s.prefix(199)) + "…" : s
  }

  // MARK: holding it

  public let path: String
  /// false: this process is inside another's hold (`PERFLOOP_LOCK_HELD`, or a lock it already holds) and took nothing.
  public let owned: Bool
  let since: String?
  private var released = false

  init(path: String, owned: Bool, since: String?) { self.path = path; self.owned = owned; self.since = since }

  static let mutex = NSLock()
  static var held: [WindowLock] = []

  /// The path of a lock this process holds, or an ancestor holds for it: nil when none.
  public static func inherited(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    mutex.lock(); let own = held.last?.path; mutex.unlock()
    if let o = own { return o }
    guard let p = env[heldVariable], !p.isEmpty, case .held(let h?) = state(at: p), h.pid != nil else { return nil }
    return p
  }

  /// What a child of this process needs to know it is inside the hold.
  public static var childEnv: [String: String] { inherited().map { [heldVariable: $0] } ?? [:] }

  /// Takes the lock at `path`, waiting while a live process holds it (`log` says who, again when the holder changes and
  /// every 5 minutes) and breaking it when its holder is gone. `check` runs between tries (a deadline throws there).
  /// Inside another hold, returns at once with a lock it doesn't own.
  public static func acquire(_ path: String, command: String = ownCommand(), label: String? = ProcessInfo.processInfo.environment[labelVariable],
                             poll: Double = 2, env: [String: String] = ProcessInfo.processInfo.environment,
                             log: (String) -> Void = { _ in }, check: () throws -> Void = {}) throws -> WindowLock {
    if let p = inherited(env: env) { return WindowLock(path: p, owned: false, since: nil) }
    var said: String?, saidAt = Date.distantPast
    while true {
      if mkdir(path, 0o755) == 0 {
        let h = Holder(pid: getpid(), command: command, label: label?.isEmpty == false ? label : nil, since: Clock.now())
        do { try PLJSON.encode(h).write(toFile: path + "/owner", atomically: true, encoding: .utf8) } catch {
          try? FileManager.default.removeItem(atPath: path)
          throw Failure(description: "couldn't write the window lock's owner file \(path)/owner: \(error)")
        }
        let l = WindowLock(path: path, owned: true, since: h.since)
        mutex.lock(); held.append(l); mutex.unlock()
        setenv(heldVariable, path, 1)
        if said != nil { log("the window lock \(path) is ours now") }
        return l
      }
      let e = errno
      var dir: ObjCBool = false
      guard e == EEXIST, FileManager.default.fileExists(atPath: path, isDirectory: &dir) else {
        throw Failure(description: "couldn't create the window lock \(path): \(String(cString: strerror(e))); point PERFLOOP_LOCK (or --lock) at a writable place, or pass --no-lock on a Mac no other bench uses")
      }
      guard dir.boolValue else { throw Failure(description: "the window lock \(path) is a file, not a directory: remove it, or point PERFLOOP_LOCK (or --lock) elsewhere") }
      switch state(at: path) {
      case .free: continue
      case .stale(let h):
        if breakStale(path, h) { log("the window lock \(path) was held by \(h.line()), which is gone: taking it over") }
        continue
      case .held(let h):
        let who = h.map { "held by \($0.line())" } ?? "held, by nobody who said so (no owner file: made by hand with mkdir? `perfloop lock -- CMD` records its holder; if nobody holds it, rmdir \(path))"
        let key = h.map { "\($0.pid ?? -1) \($0.since ?? "") \($0.raw ?? "")" } ?? "-"
        if key != said || Date().timeIntervalSince(saidAt) >= 300 { log("waiting: the window lock \(path) is \(who)"); said = key; saidAt = Date() }
      }
      try check()
      Thread.sleep(forTimeInterval: poll)
    }
  }

  /// Moves a stale lock aside and deletes it. Another waiter may have broken it and taken it afresh between our reading
  /// its holder and the move: a live holder found aside is put back.
  static func breakStale(_ path: String, _ h: Holder) -> Bool {
    let aside = path + ".stale-\(getpid())-\(UUID().uuidString.prefix(8))"
    guard rename(path, aside) == 0 else { return false }
    if let now = holder(at: aside), now != h, !gone(now) { _ = rename(aside, path); return false }
    try? FileManager.default.removeItem(atPath: aside)
    return true
  }

  /// Gives the lock back (only if its owner file is still ours: a lock someone broke and took is theirs).
  public func release() {
    Self.mutex.lock()
    guard owned, !released else { Self.mutex.unlock(); return }
    released = true
    Self.held.removeAll { $0 === self }
    let next = Self.held.last?.path
    Self.mutex.unlock()
    if let n = next { setenv(Self.heldVariable, n, 1) } else if ProcessInfo.processInfo.environment[Self.heldVariable] == path { unsetenv(Self.heldVariable) }
    if let h = Self.holder(at: path), h.pid == getpid(), h.since == since { try? FileManager.default.removeItem(atPath: path) }
  }

  /// Every lock this process holds, given back: a signal handler's or `atexit`'s last act.
  public static func releaseAll() {
    let got = mutex.try()
    let all = held
    if got { mutex.unlock() }
    for l in all.reversed() { l.release() }
  }
}

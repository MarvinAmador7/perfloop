import Foundation

// Runners and the queue (CAPABILITIES.md C10, SPEC §4.2): where a rep runs, and the experiments waiting for a machine
// nobody is using. The pure half: identities, runner names, the idle rule, the queue's records. The processes, ssh and
// IOKit are in PerfLoopRunner.

/// Where a pair ran: the runner and its machine, recorded on every pair and ledger line. Two runners are two machines
/// (a VM's numbers are another machine's), so a stage never mixes them and `diff` refuses to compare across them.
public struct RunnerIdentity: Codable, Sendable, Equatable, Hashable {
  /// "local", "ssh://Marvins-Mac-mini.local", "vm:tart/sequoia".
  public var runner: String
  /// `machine.model` (sysctl hw.model), e.g. "Mac16,10"; nil when it couldn't be read.
  public var model: String?
  /// The machine's short host name.
  public var host: String?
  public var os: String?
  public init(runner: String, model: String?, host: String? = nil, os: String? = nil) { self.runner = runner; self.model = model; self.host = host; self.os = os }

  /// Pairs recorded before runners existed ran on this Mac, unattended or not.
  public static let legacy = RunnerIdentity(runner: "local", model: nil)

  /// The ledger's key: runner and machine model.
  public var key: String { "\(runner) \(model ?? "?")" }
  /// "ssh://mini (Mac16,10, Marvins-Mac-mini)".
  public var line: String { "\(runner) (\(model ?? "unknown model")\(host.map { ", \($0)" } ?? ""))" }

  /// Same runner and, where both are known, the same model and host. An unknown field (a legacy pair) doesn't
  /// disagree: it matches the local runner of the Mac the store lives on.
  public func sameMachine(as o: RunnerIdentity) -> Bool {
    func agree(_ a: String?, _ b: String?) -> Bool { a == nil || b == nil || a == b }
    return runner == o.runner && agree(model, o.model) && agree(host, o.host)
  }

  /// Why these pairs can't be judged together (they ran on different runners), or nil.
  public static func mixed(_ pairs: [Pair]) -> String? {
    var seen: [RunnerIdentity] = []
    for p in pairs where p.failure == nil {
      let r = p.runner ?? .legacy
      if !seen.contains(where: { $0.sameMachine(as: r) }) { seen.append(r) }
    }
    guard seen.count > 1 else { return nil }
    return "pairs from different runners (\(seen.map(\.line).joined(separator: "; "))): results never mix machines; measure the stage on one runner"
  }
}

/// A runner as written on the command line: `local`, `ssh://[user@]host[:port][/store-dir]`, `vm:tart/NAME`.
public enum RunnerSpec: Equatable, Sendable {
  case local
  case ssh(user: String?, host: String, port: Int?, root: String?)
  case vm(tool: String, name: String)

  public init?(_ s: String) {
    if s == "local" { self = .local; return }
    if s.hasPrefix("ssh://") {
      var rest = String(s.dropFirst(6))
      var root: String?
      if let slash = rest.firstIndex(of: "/") { root = String(rest[slash...]); rest = String(rest[..<slash]) }
      var user: String?
      if let at = rest.lastIndex(of: "@") { user = String(rest[..<at]); rest = String(rest[rest.index(after: at)...]) }
      var port: Int?
      if let colon = rest.lastIndex(of: ":") { guard let p = Int(rest[rest.index(after: colon)...]) else { return nil }; port = p; rest = String(rest[..<colon]) }
      guard !rest.isEmpty, rest.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else { return nil }
      if let u = user, u.isEmpty || !u.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) { return nil }
      self = .ssh(user: user, host: rest, port: port, root: root == "/" ? nil : root); return
    }
    if s == "vm" { self = .vm(tool: "tart", name: "perfloop"); return }
    if s.hasPrefix("vm:") {
      let parts = s.dropFirst(3).split(separator: "/", maxSplits: 1).map(String.init)
      self = parts.count == 2 ? .vm(tool: parts[0], name: parts[1]) : .vm(tool: "tart", name: parts.first ?? "perfloop"); return
    }
    return nil
  }

  /// The runner's name in results: the user and the store directory are not part of the machine.
  public var name: String {
    switch self {
    case .local: "local"
    case .ssh(_, let h, let p, _): "ssh://\(h)" + (p.map { ":\($0)" } ?? "")
    case .vm(let t, let n): "vm:\(t)/\(n)"
    }
  }
}

/// What the idle gate saw: seconds since the last keyboard, mouse or trackpad event (IOKit `HIDIdleTime`), the frontmost
/// app, whether the screen is locked. nil where it couldn't be read.
public struct IdleReading: Sendable, Equatable {
  public var idle: Double?
  public var frontmost: String?
  public var locked: Bool?
  public init(idle: Double?, frontmost: String? = nil, locked: Bool? = nil) { self.idle = idle; self.frontmost = frontmost; self.locked = locked }

  /// `idle=130.5 frontmost=Xcode locked=0`, or a bare number of seconds (the testing hook's file).
  public init(text: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let x = Double(t) { self.init(idle: x); return }
    var d: [String: String] = [:]
    for part in t.split(whereSeparator: \.isNewline).flatMap({ $0.split(separator: " ") }) {
      let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
      if kv.count == 2 { d[kv[0]] = kv[1] }
    }
    self.init(idle: d["idle"].flatMap(Double.init), frontmost: d["frontmost"].map { $0.replacingOccurrences(of: "_", with: " ") }, locked: d["locked"].map { $0 == "1" || $0 == "true" })
  }
}

/// The local runner's rule (SPEC §4.2): start a rep only when nobody has touched the Mac for `threshold` seconds, the
/// screen is unlocked (a window behind the lock screen isn't visible) and no app that means "someone is watching" is
/// frontmost; abort the rep when input arrives (its idle time goes down).
public struct IdleGate: Sendable, Equatable {
  public var threshold: Double
  /// Frontmost apps that mean a person is there without touching anything: a call, a presentation, a film.
  public var busyApps: [String]
  public static let defaultBusyApps = ["zoom.us", "FaceTime", "Microsoft Teams", "Webex", "Keynote", "QuickTime Player", "TV", "Photo Booth"]
  public init(threshold: Double = 120, busyApps: [String] = IdleGate.defaultBusyApps) { self.threshold = threshold; self.busyApps = busyApps }

  public enum Wait: Equatable, Sendable {
    case unknown, locked, busyApp(String), recent(idle: Double, frontmost: String?)
    /// For the queue's log: one line per change of kind, not per poll.
    public var kind: String {
      switch self { case .unknown: "unknown"; case .locked: "locked"; case .busyApp(let a): "app:" + a; case .recent: "recent" }
    }
    public func text(threshold: Double) -> String {
      switch self {
      case .unknown: "can't read the idle time (HIDIdleTime): the idle gate waits; --force runs anyway"
      case .locked: "the screen is locked: a window behind the lock screen isn't visible"
      case .busyApp(let a): "\(a) is frontmost (a call, a presentation or a film: someone is there)"
      case .recent(let i, let f): "last input \(Int(i)) s ago < \(Int(threshold)) s" + (f.map { " (frontmost: \($0))" } ?? "")
      }
    }
  }

  /// nil: go. Otherwise why the rep waits.
  public func wait(_ r: IdleReading) -> Wait? {
    guard let idle = r.idle else { return .unknown }
    if r.locked == true { return .locked }
    if let f = r.frontmost, busyApps.contains(f) { return .busyApp(f) }
    if idle < threshold { return .recent(idle: idle, frontmost: r.frontmost) }
    return nil
  }

  /// During a rep: input arrived when the idle time went down since the last reading (it only grows while nobody
  /// touches the Mac; the bench's synthetic events go to its own views, not through the HID system). A lock counts too.
  public func interrupted(previous: IdleReading, now: IdleReading) -> String? {
    if now.locked == true && previous.locked != true { return "the screen locked during the rep" }
    guard let a = previous.idle, let b = now.idle else { return nil }
    if b + 0.05 < a { return "input during the rep (idle \(Stats.round(a, 1)) s → \(Stats.round(b, 1)) s" + (now.frontmost.map { ", frontmost \($0)" } ?? "") + ")" }
    return nil
  }
}

/// `--until HH:MM`: the next time the clock reads HH:MM (today, or tomorrow when it has passed).
public enum Until {
  public static func parse(_ s: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
    let p = s.split(separator: ":").map(String.init)
    guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
    var c = calendar.dateComponents([.year, .month, .day], from: now); c.hour = h; c.minute = m; c.second = 0
    guard let today = calendar.date(from: c) else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
  }
}

// MARK: the queue

/// One line of `queue.jsonl` (`perfloop.queue/1`): an item's state change. Append-only like the ledger, so a `queue add`
/// while `queue run` works never loses either's write; an item's state is its newest line.
public struct QueueEvent: Codable, Sendable, Equatable {
  public var schema = "perfloop.queue/1"
  public var at: String
  /// "q1", "q2", …
  public var item: String
  /// queued | running | waiting | done | failed | stopped | removed. `waiting` and `stopped` leave the item queued.
  public var state: String
  public var experiment: String?
  /// screen | full | auto (screen, then the full when it is promising).
  public var stage: String?
  /// The runner it must run on (nil: whichever runs the queue); on running/done lines, the one it ran on.
  public var runner: String?
  public var note: String?
  /// `queue add --force`: run the full even when the screen rejected it (`exp full --force`).
  public var force: Bool?
  public init(item: String, state: String, experiment: String? = nil, stage: String? = nil, runner: String? = nil, note: String? = nil, force: Bool? = nil, at: String = Clock.now()) {
    self.at = at; self.item = item; self.state = state; self.experiment = experiment; self.stage = stage; self.runner = runner; self.note = note; self.force = force
  }
}

public struct QueueItem: Sendable, Equatable {
  public var id: String
  public var experiment: String
  public var stage: String
  public var runner: String?
  public var addedAt: String
  /// queued | running | done | failed | removed.
  public var state: String
  public var updatedAt: String
  public var note: String?
  /// The newest reason it waited, and when.
  public var lastWait: String?
  public var ranOn: String?
  public var force = false
  public var pending: Bool { state == "queued" }
}

public struct Queue: Sendable {
  public let path: String
  public init(path: String) { self.path = path }
  public static let stages = ["screen", "full", "auto"]

  public func append(_ e: QueueEvent) throws { try JSONLines.append(PLJSON.line(e), path: path) }
  public func events() -> [QueueEvent] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { try? PLJSON.decode(QueueEvent.self, from: Data($0.utf8)) }
  }

  /// Every item, oldest first, in its newest state.
  public func items() -> [QueueItem] {
    var order: [String] = [], d: [String: QueueItem] = [:]
    for e in events() {
      if var it = d[e.item] {
        switch e.state {
        case "waiting": it.lastWait = "\(e.at) \(e.note ?? "")"
        case "stopped": it.state = "queued"; it.note = e.note
        default: it.state = e.state; it.note = e.note ?? it.note
        }
        if e.state == "running" || e.state == "done" { it.ranOn = e.runner ?? it.ranOn }
        it.updatedAt = e.at
        d[e.item] = it
      } else if e.state == "queued", let x = e.experiment {
        order.append(e.item)
        d[e.item] = QueueItem(id: e.item, experiment: x, stage: e.stage ?? "auto", runner: e.runner, addedAt: e.at, state: "queued", updatedAt: e.at, note: e.note, force: e.force == true)
      }
    }
    return order.compactMap { d[$0] }
  }

  public func nextID() -> String {
    let n = Set(events().map(\.item)).compactMap { Int($0.dropFirst()) }.max() ?? 0
    return "q\(n + 1)"
  }

  /// The items a `queue run` on `runner` takes, oldest first: queued, and for that runner or any. An item left
  /// `running` by a run that died (`stale`) is taken again: its stage resumes at the first missing pair.
  public func runnable(on runner: String, stale: (QueueItem) -> Bool = { _ in false }) -> [QueueItem] {
    items().filter { ($0.state == "queued" || ($0.state == "running" && stale($0))) && ($0.runner == nil || $0.runner == runner) }
  }

  public static func text(_ items: [QueueItem]) -> String {
    if items.isEmpty { return "the queue is empty" }
    return items.map { it in
      var l = "\(it.id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(it.state.padding(toLength: 8, withPad: " ", startingAt: 0)) exp \(it.experiment) \(it.stage)\(it.force ? " --force" : "") on \(it.runner ?? "any runner") · added \(it.addedAt)"
      if let r = it.ranOn, it.state != "queued" { l += " · ran on \(r)" }
      if let n = it.note { l += "\n       \(n)" }
      if let w = it.lastWait, it.state == "queued" || it.state == "running" { l += "\n       waited: \(w)" }
      return l
    }.joined(separator: "\n")
  }
}

/// Appending one line to a JSONL file as one write, closing a torn last line first (the ledger's rule).
public enum JSONLines {
  public static func append(_ line: String, path: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: path) else { throw CocoaError(.fileWriteUnknown) }
    defer { try? h.close() }
    let end = try h.seekToEnd()
    var torn = false
    if end > 0, let r = FileHandle(forReadingAtPath: path) {
      try r.seek(toOffset: end - 1); torn = try r.read(upToCount: 1) != Data("\n".utf8); try r.close()
    }
    try h.write(contentsOf: Data(((torn ? "\n" : "") + line + "\n").utf8))
  }
}

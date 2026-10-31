import Foundation
import PerfLoopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The queue (C10): experiments waiting for a free runner. `queue add` appends to `queue.jsonl`; `queue run --runner R`
/// takes the oldest queued item for R (or any runner), runs its stage (`screen`, `full`, or `auto`: the screen, then
/// the full when the screen is promising) on R, and records where it ran and why it waited. Results land in the
/// ledger as any stage's do. One `queue run` per runner at a time (a lock in the store).
extension Loop {
  public var queue: Queue { Queue(path: store.root.appendingPathComponent("queue.jsonl").path) }

  @discardableResult
  public func queueAdd(_ exp: String, stage: String = "auto", runner: String? = nil, note: String? = nil, force: Bool = false) throws -> QueueItem {
    guard Queue.stages.contains(stage) else { throw PLError.usage("--stage screen|full|auto") }
    if let r = runner, RunnerSpec(r) == nil { throw PLError.usage("unknown runner '\(r)'") }
    let e = try store.experiment(exp)
    guard e.kind != "baseline" else { throw PLError.usage("exp \(e.id) is the baseline") }
    if e.state.terminal { throw PLError.refused("exp \(e.id) is \(e.state.rawValue): nothing left to run") }
    if e.state == .rejected && !force && stage != "screen" { throw PLError.refused("exp \(e.id) was rejected by its screen; --force queues its full anyway") }
    if stage == "full" && e.state == .built { throw PLError.usage("exp \(e.id) isn't screened: queue it with --stage auto (screen, then full when promising)") }
    let q = queue
    if let dup = q.items().first(where: { $0.experiment == e.id && ($0.state == "queued" || $0.state == "running") }) {
      throw PLError.refused("exp \(e.id) is already queued as \(dup.id) (\(dup.stage) on \(dup.runner ?? "any runner"))")
    }
    let id = q.nextID()
    let name = runner.flatMap { RunnerSpec($0)?.name }
    try q.append(QueueEvent(item: id, state: "queued", experiment: e.id, stage: stage, runner: name, note: note, force: force ? true : nil))
    return q.items().first { $0.id == id }!
  }

  public func queueRemove(_ id: String) throws {
    let q = queue
    guard let it = q.items().first(where: { $0.id == id }) else { throw PLError.usage("no queue item \(id)") }
    guard it.state == "queued" else { throw PLError.refused("\(id) is \(it.state)") }
    try q.append(QueueEvent(item: id, state: "removed"))
  }

  public struct QueueRunResult { public var lines: [String] = []; public var ran = 0; public var stopped: String? }

  /// Runs queued items on `runner` until the queue is empty or `until` (no rep starts after it; the item stays queued
  /// and its stage resumes at the first missing pair next time).
  public func queueRun(on r: Runner, until: Date? = nil) throws -> QueueRunResult {
    var res = QueueRunResult()
    let lock = try RunnerLock.acquire(store: store, runner: r.name)
    defer { lock.release(); r.close() }
    r.deadline = until
    let q = queue
    var current: String?
    r.onWait = { line in if let c = current { try? q.append(QueueEvent(item: c, state: "waiting", runner: r.name, note: line)) } }
    let saved = runner
    runner = r
    defer { runner = saved }
    var tried = Set<String>()
    while let it = q.runnable(on: r.name, stale: { lock.isStale($0) }).first(where: { !tried.contains($0.id) }) {
      tried.insert(it.id)
      current = it.id
      if let u = until, Date() >= u { res.stopped = "reached --until \(Clock.iso(u))"; break }
      do {
        let id = try r.identity()
        try q.append(QueueEvent(item: it.id, state: "running", experiment: it.experiment, stage: it.stage, runner: r.name, note: "pid \(getpid()) on \(id.line)"))
        log("queue \(it.id): exp \(it.experiment) \(it.stage) on \(id.line)")
        let e = try runStage(it)
        let line = "exp \(e.id) → \(e.state.rawValue)" + ((e.full ?? e.screen).map { " (\($0.verdict))" } ?? "")
        try q.append(QueueEvent(item: it.id, state: "done", runner: r.name, note: line))
        res.lines.append("\(it.id): \(line) on \(id.line)"); res.ran += 1
      } catch let s as RunnerStop {
        try q.append(QueueEvent(item: it.id, state: "stopped", runner: r.name, note: "\(s); its stage resumes at the first missing pair"))
        res.stopped = s.description; res.lines.append("\(it.id): stopped: \(s)")
        break
      } catch {
        let why = (error as? PLError)?.description ?? "\(error)"
        try q.append(QueueEvent(item: it.id, state: "failed", runner: r.name, note: why))
        res.lines.append("\(it.id): failed: \(why)")
        // A runner that can't be reached fails every item the same way: stop rather than burn the queue.
        if case PLError.harness(let m) = error, m.hasPrefix(r.name + ":") { res.stopped = m; break }
      }
      current = nil
    }
    if res.ran == 0 && res.lines.isEmpty { res.lines.append("nothing queued for \(r.name)") }
    return res
  }

  func runStage(_ it: QueueItem) throws -> Experiment {
    var e = try store.experiment(it.experiment)
    switch it.stage {
    case "screen": return try screen(e.id)
    case "full": return try full(e.id, force: it.force)
    default:
      if e.screen == nil || e.screen?.verdict == "error" { e = try screen(e.id) }
      if [.promising, .full].contains(e.state) || (it.force && e.state == .rejected) { e = try full(e.id, force: it.force) }
      return e
    }
  }
}

/// One `queue run` per runner and store: `<store>/runners/<runner>.lock/` holding the pid. A lock whose process is
/// gone is taken over.
public struct RunnerLock {
  let dir: URL
  let pid: Int32

  public static func acquire(store: Store, runner: String) throws -> RunnerLock {
    let safe = runner.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "_" }
    let dir = store.root.appendingPathComponent("runners").appendingPathComponent(String(safe) + ".lock")
    let fm = FileManager.default
    try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
    for _ in 0..<2 {
      if (try? fm.createDirectory(at: dir, withIntermediateDirectories: false)) != nil {
        try String(getpid()).write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        return RunnerLock(dir: dir, pid: getpid())
      }
      let other = (try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      if let o = other, ProcessTree.sysKill(o, 0) == 0 { throw PLError.refused("\(runner) is busy: queue run pid \(o) holds \(dir.path)") }
      try? fm.removeItem(at: dir)                                   // its process is gone
    }
    throw PLError.harness("couldn't take \(dir.path)")
  }

  /// An item left `running` by another, dead `queue run` (its note says "pid N").
  func isStale(_ it: QueueItem) -> Bool {
    guard let n = it.note, n.hasPrefix("pid "), let p = Int32(n.dropFirst(4).prefix { $0.isNumber }) else { return true }
    return p != pid && ProcessTree.sysKill(p, 0) != 0
  }

  public func release() { try? FileManager.default.removeItem(at: dir) }
}

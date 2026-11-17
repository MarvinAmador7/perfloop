import Foundation
import PerfLoopKit

// `perfloop profile champion|exp/ID` (C2): the adapter's own xctrace recording of a store build (with the experiment's
// knobs), kept in the store as a `perfloop.profile/2` and indexed by build, knobs, scenario and template, so that
// `perfloop diff champion exp/ID` finds both sides by name and checks their provenance. The trace holds the recorded
// process's environment (tokens included): once the adapter returns, the runner deletes every `.trace` it left unless
// `--keep-trace`, checks that it is gone, and the profile says what is on disk, not what the adapter meant to do. And
// the adapter starts with a scrubbed environment (TraceEnv: an allowlist and the names its manifest declares in
// `profileEnv`), so a kept trace carries no tokens even when the adapter passes its whole environment on.

extension Loop {
  /// What a name like `champion` or `exp/0007` stands for: the build to record, the knobs it runs with, and the scenario
  /// and fixture (the experiment's, or the champion's baseline's).
  public struct ProfileTarget: Equatable {
    public var label: String
    public var build: String
    public var knobs: [String: String]
    public var scenario: String
    public var fixture: String
    public var experiment: String?
  }

  public static func isProfileTarget(_ x: String) -> Bool { x == "champion" || x.hasPrefix("exp/") }

  public func profileTarget(_ x: String, scenario: String? = nil, fixture: String? = nil) throws -> ProfileTarget {
    let (c, entry) = try requireChampion()
    if x == "champion" {
      let base = try? store.experiment(c.experiment)
      return ProfileTarget(label: "champion-\(c.experiment)", build: entry.build.hash ?? "", knobs: c.knobs ?? [:], scenario: scenario ?? base?.scenario ?? "-",
                           fixture: fixture ?? base?.fixture ?? "-", experiment: c.experiment)
    }
    guard x.hasPrefix("exp/") else { throw PLError.usage("\(x): profile champion or exp/ID") }
    let e = try store.experiment(String(x.dropFirst(4)))
    let b = e.build ?? e.parent?.build ?? c.build
    let ck = c.experiment == e.parent?.experiment ? (c.knobs ?? [:]) : [:]
    return ProfileTarget(label: "exp-\(e.id)", build: b.hash ?? "", knobs: ck.merging(e.knobs ?? [:]) { $1 }, scenario: scenario ?? e.scenario,
                         fixture: fixture ?? e.fixture, experiment: e.id)
  }

  /// Records a profile of `target` with its adapter's `profile` verb (it opens the window: this Mac only, through the
  /// local runner, so its idle gate and window lock apply) and indexes it. Returns the profile's path and the document.
  public func profile(_ target: String, template: String = "time", scenario: String? = nil, fixture: String? = nil, keepTrace: Bool = false) throws -> (path: String, doc: ProfileDoc) {
    let t = try profileTarget(target, scenario: scenario, fixture: fixture)
    let entry = try store.entry(t.build)
    if let m = entry.manifest, !m.has(verb: "profile") {
      throw PLError.usage("\(target)'s adapter (\(m.adapter)) has no `profile` verb: rebuild the bench on a PerfLoopHost with profiles (or record a trace by hand and `perfloop trace register` it)")
    }
    guard runner is LocalRunner else { throw PLError.usage("profiles record on this Mac (xctrace attaches to the bench here): use --runner local, not \(runner.name)") }
    let dir = store.root.appendingPathComponent("profiles").appendingPathComponent("\(t.label)-\(t.scenario)-\(template)-\(Clock.now().replacingOccurrences(of: ":", with: ""))")
    var args = ["profile", t.scenario, "--template", template, "--fixture", t.fixture, "--out", dir.path, "--json"]
    for (k, v) in t.knobs.sorted(by: { $0.key < $1.key }) { args += ["--knob", "\(k)=\(v)"] }
    if keepTrace { args.append("--keep-trace") }
    let path = dir.appendingPathComponent("\(t.scenario)-\(template).json").path
    // While it records, `store gc` and `doctor` leave this folder's trace alone.
    let marker = dir.appendingPathComponent(Traces.marker)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? String(ProcessInfo.processInfo.processIdentifier).write(to: marker, atomically: true, encoding: .utf8)
    let o: Adapter.Output
    let env = TraceEnv.scrub(ProcessInfo.processInfo.environment, declared: entry.manifest?.profileEnv ?? [])
    do { o = try Adapter(exe: entry.executable, runner: runner, workDir: dir).call(args, env: env, inherit: false) } catch {
      let s = settleTraces(dir: dir, reported: nil, keep: keepTrace); try? FileManager.default.removeItem(at: marker)
      if s.kept.isEmpty { throw error }
      throw PLError.harness("\(error)" + s.failureNote)
    }
    let written = try? PLJSON.read(ProfileDoc.self, path: path)
    let s = settleTraces(dir: dir, reported: written?.trace, keep: keepTrace)
    try? FileManager.default.removeItem(at: marker)
    if o.status == interruptedStatus { throw PLError.harness("the profile was interrupted (input on this Mac): run it again when nobody is using the Mac" + s.failureNote) }
    guard o.status == 0, var doc = written else {
      throw PLError.harness("\(entry.executable) profile exited \(o.status) without a profile at \(path)" + s.failureNote)
    }
    s.apply(&doc)
    try s.patch(path)
    try appendIndex(.object(["path": .string(path), "build": .string(t.build), "knobs": .object(t.knobs.mapValues { .string($0) }), "scenario": .string(t.scenario),
                             "fixture": .string(t.fixture), "template": .string(doc.template), "target": .string(t.label), "at": .string(Clock.now())]))
    if let id = t.experiment, target.hasPrefix("exp/"), var e = try? store.experiment(id) {
      e.notes.append("profile (\(doc.template)): \(store.rel(URL(fileURLWithPath: path)))"); try store.save(e); _ = explain(e)
    }
    return (path, doc)
  }

  /// What is on disk after a profile: the traces still there (kept on purpose, or a delete that failed, with why).
  struct SettledTraces {
    var kept: [String] = []
    var failed: [String: String] = [:]
    var keep = false

    /// Into the document: `traceKept` and `trace` as they are on disk, and a note per trace still there that shouldn't be.
    func apply(_ d: inout ProfileDoc) {
      d.traceKept = !kept.isEmpty
      d.keepTrace = keep ? true : nil
      if let k = kept.first { d.trace = k }
      d.notes += notes
    }
    var notes: [String] {
      kept.dropFirst().map { "also kept: \($0)" } + failed.sorted(by: { $0.key < $1.key }).map { p, why in
        "couldn't delete \(p) (\(why)): it holds the recorded process's environment; delete it by hand, or perfloop store gc"
      }
    }
    /// The same into the profile JSON on disk (patched as JSON: fields this runner doesn't know are kept).
    func patch(_ path: String) throws {
      guard case .object(var o)? = try? PLJSON.read(JSONValue.self, path: path) else { return }
      o["traceKept"] = .bool(!kept.isEmpty)
      o["keepTrace"] = keep ? .bool(true) : nil
      if let k = kept.first { o["trace"] = .string(k) }
      if !notes.isEmpty { o["notes"] = .array((o["notes"]?.array ?? []) + notes.map(JSONValue.string)) }
      try PLJSON.write(JSONValue.object(o), path: path)
    }
    /// For an error: the traces left behind.
    var failureNote: String {
      kept.isEmpty ? "" : "\n" + kept.map { "trace: KEPT at \($0)\(failed[$0].map { " (couldn't delete it: \($0))" } ?? ""): it holds the recorded process's environment; delete it by hand, or perfloop store gc" }.joined(separator: "\n")
    }
  }

  /// Deletes every `.trace` the adapter left in `dir` (and the one its document names, wherever it is) unless `keep`,
  /// then reads what is left.
  func settleTraces(dir: URL, reported: String?, keep: Bool) -> SettledTraces {
    var s = SettledTraces(); s.keep = keep
    var found = Traces.find(under: dir).map(\.path)
    if let r = reported, URL(fileURLWithPath: r).pathExtension == "trace", FileManager.default.fileExists(atPath: r),
       !found.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL == URL(fileURLWithPath: r).standardizedFileURL }) { found.append(r) }
    for p in found {
      if keep { s.kept.append(p); continue }
      if let why = Traces.delete(p) { s.kept.append(p); s.failed[p] = why }
    }
    return s
  }

  /// The newest indexed profile of a target (same build, knobs and scenario), Time Profiler first.
  public func latestProfile(_ t: ProfileTarget, template: String? = nil) -> String? {
    let lines = ((try? String(contentsOfFile: store.root.appendingPathComponent("traces/index.jsonl").path, encoding: .utf8)) ?? "").split(separator: "\n")
    let rows = lines.compactMap { try? PLJSON.decode(JSONValue.self, from: Data($0.utf8)) }.filter { v in
      guard v["build"]?.string == t.build, v["scenario"]?.string == t.scenario, let p = v["path"]?.string, FileManager.default.fileExists(atPath: p) else { return false }
      let k = (v["knobs"]?.object ?? [:]).compactMapValues(\.string)
      return k == t.knobs
    }
    let want = template.flatMap { ProfileDoc.templates[$0] ?? $0 }
    let pick = rows.last { $0["template"]?.string == (want ?? "Time Profiler") } ?? (want == nil ? rows.last : nil)
    return pick?["path"]?.string
  }

  func appendIndex(_ v: JSONValue) throws {
    let idx = store.root.appendingPathComponent("traces/index.jsonl")
    try FileManager.default.createDirectory(at: idx.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: idx.path) { FileManager.default.createFile(atPath: idx.path, contents: nil) }
    let h = try FileHandle(forWritingTo: idx); try h.seekToEnd()
    try h.write(contentsOf: Data((PLJSON.line(v) + "\n").utf8)); try h.close()
  }
}

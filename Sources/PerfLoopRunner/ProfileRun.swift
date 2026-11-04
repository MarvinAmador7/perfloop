import Foundation
import PerfLoopKit

// `perfloop profile champion|exp/ID` (C2): the adapter's own xctrace recording of a store build (with the experiment's
// knobs), kept in the store as a `perfloop.profile/2` and indexed by build, knobs, scenario and template, so that
// `perfloop diff champion exp/ID` finds both sides by name and checks their provenance. The trace itself is deleted by
// the adapter once exported (it holds the recorded process's environment) unless `--keep-trace`.

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
    let o = try Adapter(exe: entry.executable, runner: runner, workDir: dir).call(args)
    if o.status == interruptedStatus { throw PLError.harness("the profile was interrupted (input on this Mac): run it again when nobody is using the Mac") }
    let path = dir.appendingPathComponent("\(t.scenario)-\(template).json").path
    guard o.status == 0, let doc = try? PLJSON.read(ProfileDoc.self, path: path) else {
      throw PLError.harness("\(entry.executable) profile exited \(o.status) without a profile at \(path)")
    }
    try appendIndex(.object(["path": .string(path), "build": .string(t.build), "knobs": .object(t.knobs.mapValues { .string($0) }), "scenario": .string(t.scenario),
                             "fixture": .string(t.fixture), "template": .string(doc.template), "target": .string(t.label), "at": .string(Clock.now())]))
    if let id = t.experiment, target.hasPrefix("exp/"), var e = try? store.experiment(id) {
      e.notes.append("profile (\(doc.template)): \(store.rel(URL(fileURLWithPath: path)))"); try store.save(e); _ = explain(e)
    }
    return (path, doc)
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

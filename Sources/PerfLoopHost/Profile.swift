#if os(macOS)
import Foundation
import os
import PerfLoopKit
import PerfLoopProbe

/// The `step` signposts every `run.step` emits (cheap when nothing records them): what a profile's per-step call trees
/// are cut on (`StepInterval.fromSignposts`). Points of Interest, so the Time Profiler template records them too.
enum StepSignposts {
  static let poster = OSSignposter(subsystem: StepInterval.hostSubsystem, category: .pointsOfInterest)
}

/// `profile SCENARIO --template time|hitches|swiftui` and `diff A B`: the bench's own xctrace recording and the
/// differential call tree (CAPABILITIES.md C2; deskbench's `profile` and `diff`, generic). The bench starts itself as a
/// child (`run … --wait-for FILE --profiled`), which shows the window and waits; `xctrace record --attach` attaches to
/// it; the child runs its reps and says when it is done; the recording is stopped with SIGINT (xctrace saves, as on
/// Ctrl-C), so it covers every step and no time limit cuts it short. Then the tables are exported and summarised into a
/// `perfloop.profile/2`, and the trace is deleted unless `--keep-trace` (a trace holds the recorded process's environment;
/// the child and xctrace get a scrubbed one anyway).
enum ProfileVerb {
  static let usage = """
  usage: BENCH profile SCENARIO [--template time|hitches|swiftui] [--fixture F] [--reps N] [--set k=v] [--knob k=v]
                       [--out DIR] [--keep-trace] [--seconds S] [--no-activate] [--json]
         BENCH diff A B [--top N] [--per step|run] [--min-ms X] [--process NAME] [--champion BUILD] [--allow-stale] [--allow-cross-os] [--json]
    profile: opens the window (as `run` does) under xctrace and writes DIR/SCENARIO-TEMPLATE.json (perfloop.profile/2).
             DIR defaults to ${PERFLOOP_HOME:-~/.perfloop}/APP/profiles/<time>-SCENARIO-TEMPLATE. Its numbers never decide.
    diff:    A and B are profile JSONs or .trace files: what grew and shrank, ms per step, main thread (perfloop.diff/1).
  """

  /// What a recorded process keeps of our environment: no tokens, keys or logins end up in the trace.
  static let allowedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING", "DEVELOPER_DIR"]
  static func scrub(_ env: [String: String]) -> [String: String] {
    env.filter { k, _ in allowedKeys.contains(k) || k.hasPrefix("LC_") || k.hasPrefix("PERFLOOP_") }
  }

  static func defaultDir(app: String, scenario: String, template: String) -> URL {
    let env = ProcessInfo.processInfo.environment
    let home = env["PERFLOOP_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".perfloop")
    let stamp = Clock.now().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
    return home.appendingPathComponent(app).appendingPathComponent("profiles").appendingPathComponent("\(stamp)-\(scenario)-\(template)")
  }

  /// The git checkout a path is inside, if any.
  static func checkout(containing path: String) -> String? {
    var u = URL(fileURLWithPath: path).standardizedFileURL
    while u.path != "/" && !u.path.isEmpty {
      if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { return u.path }
      u = u.deletingLastPathComponent()
    }
    return nil
  }

  // MARK: record

  @MainActor
  static func record(_ bench: Bench, _ a: HostArgs) -> (Int32, String) {
    guard let scenario = a.positional.dropFirst().first else { return (1, usage) }
    guard bench.scenarios.contains(where: { $0.name == scenario }) else { return (1, "\(bench.adapter): unknown scenario '\(scenario)' (scenarios: \(bench.scenarios.map(\.name).joined(separator: ", ")))") }
    let template = a.one("template") ?? "time"
    guard let tname = ProfileDoc.templates[template] else { return (1, "--template takes \(ProfileDoc.templates.keys.sorted().joined(separator: ", "))") }
    let out = a.one("out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultDir(app: bench.app, scenario: scenario, template: template)
    let keep = a.has("keep-trace")
    if keep, let repo = checkout(containing: out.path), !a.has("allow-in-repo") {
      return (6, "\(bench.adapter): \(out.path) is inside the git checkout \(repo): a kept trace holds the recorded process's environment (--out elsewhere)")
    }
    do {
      let doc = try record(bench: bench, scenario: scenario, template: template, tname: tname, out: out, keep: keep, a: a)
      return (doc.tree == nil && doc.hitches == nil && doc.swiftUI == nil ? 2 : 0, a.has("json") ? PLJSON.encode(doc) : doc.text + "\nwritten: \(out.path)/\(scenario)-\(template).json")
    } catch let e as HostError { return (e.code, "\(bench.adapter): \(e)") } catch { return (2, "\(bench.adapter): \(error)") }
  }

  @MainActor
  static func record(bench: Bench, scenario: String, template: String, tname: String, out: URL, keep: Bool, a: HostArgs) throws -> ProfileDoc {
    let fm = FileManager.default
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let go = out.appendingPathComponent("go"), trace = out.appendingPathComponent("\(scenario)-\(template).trace"), result = out.appendingPathComponent("\(scenario)-inprocess.json")
    let waiting = URL(fileURLWithPath: go.path + ".waiting"), done = URL(fileURLWithPath: go.path + ".done")
    for f in [go, waiting, done, trace, result] { try? fm.removeItem(at: f) }
    let fixture = a.one("fixture") ?? bench.defaultFixture ?? bench.fixtures.first?.name ?? "default"
    var args = ["run", scenario, "--fixture", fixture, "--reps", a.one("reps") ?? "1", "--json", "--out", result.path, "--wait-for", go.path, "--profiled",
                "--sampler", a.one("sampler") ?? "off"]
    for s in a.all("set") { args += ["--set", s] }
    for k in a.all("knob") { args += ["--knob", k] }
    if a.has("no-activate") { args.append("--no-activate") }
    let env = scrub(ProcessInfo.processInfo.environment)
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let child = Process()
    child.executableURL = URL(fileURLWithPath: exe); child.arguments = args; child.environment = env
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.standardError
    do { try child.run() } catch { throw HostError.harness("couldn't start \(exe): \(error)") }
    defer { if child.isRunning { child.terminate() } }
    // The window is up and at rest when the child says it waits.
    let up = Date().addingTimeInterval(30)
    while child.isRunning, !fm.fileExists(atPath: waiting.path), Date() < up { Thread.sleep(forTimeInterval: 0.05) }
    guard child.isRunning, fm.fileExists(atPath: waiting.path) else { throw HostError.harness("the bench's window didn't come up (exit \(child.isRunning ? "none, timed out" : String(child.terminationStatus)))") }

    let limit = Double(a.one("seconds") ?? "") ?? 600
    let rec = Process()
    rec.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); rec.environment = env
    rec.arguments = ["xctrace", "record", "--template", tname, "--attach", String(child.processIdentifier), "--output", trace.path, "--time-limit", "\(Int(limit))s"]
    let pipe = Pipe(); rec.standardOutput = pipe; rec.standardError = pipe
    let log = LogBuffer()
    pipe.fileHandleForReading.readabilityHandler = { h in log.append(h.availableData) }
    let started = Date()
    do { try rec.run() } catch { throw HostError.harness("couldn't start xcrun xctrace (Xcode's command line tools): \(error)") }
    defer { if rec.isRunning { rec.terminate() } }
    // xctrace prints "Ctrl-C to stop the recording" once attached; a second more so the first step is inside it.
    let ready = Date().addingTimeInterval(30)
    while !log.text.contains("Ctrl-C"), rec.isRunning, Date() < ready { Thread.sleep(forTimeInterval: 0.05) }
    guard rec.isRunning else { throw HostError.harness("xctrace stopped before it attached:\n\(log.text.suffix(800))") }
    Thread.sleep(forTimeInterval: 1.0)
    fm.createFile(atPath: go.path, contents: Data())
    while child.isRunning, !fm.fileExists(atPath: done.path) { Thread.sleep(forTimeInterval: 0.05) }
    let stopped = Date(), hitLimit = !rec.isRunning && child.isRunning
    if rec.isRunning { rec.interrupt() }   // SIGINT: stop and save, as Ctrl-C does
    child.waitUntilExit()
    let saveBy = Date().addingTimeInterval(180)
    while rec.isRunning, Date() < saveBy { Thread.sleep(forTimeInterval: 0.1) }
    if rec.isRunning { rec.terminate(); rec.waitUntilExit() }
    pipe.fileHandleForReading.readabilityHandler = nil
    log.append(pipe.fileHandleForReading.readDataToEndOfFile())
    for f in [go, waiting, done] { try? fm.removeItem(at: f) }
    guard fm.fileExists(atPath: trace.path) else { throw HostError.harness("xctrace wrote no trace:\n\(log.text.suffix(800))") }

    var doc = ProfileDoc(template: tname, trace: trace.path, scenario: scenario, fixture: fixture, process: URL(fileURLWithPath: exe).lastPathComponent,
                         durationS: Stats.round(stopped.timeIntervalSince(started), 1))
    doc.build = bench.build
    doc.knobs = Knobs.parse(env[Knobs.variable] ?? "").merging(a.all("knob").reduce(into: [:]) { $0.merge(Knobs.parse($1)) { $1 } }) { $1 }
    if doc.knobs?.isEmpty == true { doc.knobs = nil }
    if hitLimit { doc.notes.append("xctrace stopped before the reps were done (the --seconds \(Int(limit)) limit?): later steps may be missing") }
    if let d = try? Data(contentsOf: result), let v = try? PLJSON.decode(JSONValue.self, from: d) { doc.inProcess = v }
    else { doc.notes.append("the child wrote no in-process result (exit \(child.terminationStatus))") }
    try? fm.removeItem(at: result)
    try summarise(&doc, trace: trace, template: template)
    if keep {
      doc.traceKept = true
      FileHandle.standardError.write(Data("\(bench.adapter): \(trace.path) holds the recorded process's environment and paths: never commit, publish or attach it\n".utf8))
    } else {
      try? fm.removeItem(at: trace); doc.traceKept = false
    }
    try PLJSON.encode(doc).write(to: out.appendingPathComponent("\(scenario)-\(template).json"), atomically: true, encoding: .utf8)
    return doc
  }

  /// Exports what the template recorded and folds it into the document.
  static func summarise(_ doc: inout ProfileDoc, trace: URL, template: String) throws {
    let toc = String(decoding: try export(trace, xpath: nil), as: UTF8.self)
    // From the TOC only the OS build, the model and the recorded process's name are read (it also lists the environment).
    doc.os = firstMatch(#"<device [^>]*os-version="([^"]*)""#, in: toc).map { v in firstMatch(#"<device [^>]*os-build="([^"]*)""#, in: toc).map { "\(v) (\($0))" } ?? v }
    doc.model = firstMatch(#"<device [^>]*model="([^"]*)""#, in: toc)
    if let p = firstMatch(#"<process type="attached"[^>]* name="([^"]*)""#, in: toc) { doc.process = p }
    func table(_ schema: String) -> XCTable? {
      guard toc.contains("schema=\"\(schema)\"") else { return nil }
      guard let d = try? export(trace, xpath: "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]") else { return nil }
      return try? XCTable(xml: d)
    }
    let signposts = table("os-signpost")
    if let s = signposts { doc.addSignposts(s) }
    switch template {
    case "hitches":
      if let h = table("hitches") { doc.hitches = HitchSummary(hitches: h, hangs: table("potential-hangs"), process: doc.process) }
      else { doc.notes.append("no hitches table in the trace") }
    case "swiftui":
      var tables: [String: XCTable] = [:]
      for name in SwiftUIProfile.tableNames { if let t = table(name) { tables[name] = t } }
      let s = SwiftUIProfile(tables: tables, process: doc.process)
      doc.swiftUI = s
      if tables.isEmpty { doc.notes.append("no SwiftUI tables in the trace") }
      else if s.empty { doc.notes.append("the SwiftUI tables have no rows; the in-process causes (worstStretches[].causes) are the record") }
      if let t = table("time-profile") { doc.addCallTrees(timeProfile: t, signposts: signposts, process: doc.process) }
    default:
      if let t = table("time-profile") { doc.addCallTrees(timeProfile: t, signposts: signposts, process: doc.process) } else { doc.notes.append("no time-profile table in the trace") }
      if let h = table("potential-hangs") { doc.hitches = HitchSummary(hitches: .empty, hangs: h, process: doc.process) }
    }
  }

  /// `xctrace export` to memory; `xpath` nil exports the TOC.
  static func export(_ trace: URL, xpath: String?) throws -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["xctrace", "export", "--input", trace.path] + (xpath.map { ["--xpath", $0] } ?? ["--toc"])
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try p.run()
    let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return d
  }

  static func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
  }

  // MARK: diff

  static func diff(_ a: HostArgs) -> (Int32, String) {
    let files = Array(a.positional.dropFirst())
    guard files.count == 2 else { return (1, usage) }
    let began = Date()
    let per = a.one("per") ?? "step"
    guard per == "step" || per == "run" else { return (1, "--per takes step or run") }
    var loaded: [Result<DiffInput, Error>] = Array(repeating: .failure(HostError.harness("not loaded")), count: 2)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 2) { i in
      let r = Result { try load(files[i], process: a.one("process"), per: per) }
      lock.lock(); loaded[i] = r; lock.unlock()
    }
    let x: DiffInput, y: DiffInput
    do { x = try loaded[0].get(); y = try loaded[1].get() } catch { return (2, "diff: \(error)") }
    let prov = Diff.provenance(a: x.side, b: y.side, champion: a.one("champion"), allowStale: a.has("allow-stale"), allowCrossOS: a.has("allow-cross-os"))
    let top = a.one("top").flatMap(Int.init) ?? 8
    var r = Diff.make(a: x, b: y, normalisation: per == "run" ? "msPerRun" : "msPerStep", top: top, minMs: a.one("min-ms").flatMap(Double.init), provenance: prov)
    r.elapsedS = Stats.round(Date().timeIntervalSince(began), 1)
    if prov.refused {
      return (6, a.has("json") ? PLJSON.encode(r) : "diff refused: \(prov.reasons.joined(separator: "; ")). --allow-stale / --allow-cross-os compare anyway.")
    }
    return (0, a.has("json") ? PLJSON.encode(r) : Explain.diffText(r, top: top))
  }

  /// One side: a profile JSON (its trees) or a `.trace` (exported here).
  static func load(_ path: String, process: String?, per: String) throws -> DiffInput {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    if url.pathExtension == "trace" { return try fromTrace(url, process: process, per: per) }
    let p = try PLJSON.decode(ProfileDoc.self, from: Data(contentsOf: url))
    if let i = Diff.input(profile: p, path: url.path, per: per) { return i }
    if let t = p.trace, p.traceKept == true, FileManager.default.fileExists(atPath: t) {
      var i = try fromTrace(URL(fileURLWithPath: t), process: process ?? p.process, per: per, inProcessSteps: p.inProcessSteps)
      i.side.profile = url.path; i.side.build = p.build.map { DiffBuild(hash: $0.hash, commit: $0.commit, dirty: $0.dirty, stamp: $0.stamp) }
      return i
    }
    throw HostError.harness("\(url.path) has no call tree (record it with --template time)")
  }

  static func fromTrace(_ url: URL, process: String?, per: String, inProcessSteps: Int? = nil) throws -> DiffInput {
    guard FileManager.default.fileExists(atPath: url.path) else { throw HostError.usage("no such trace: \(url.path)") }
    let xpaths = ["/trace-toc/run[@number=\"1\"]/data/table[@schema=\"time-profile\"]", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"os-signpost\"]", nil]
    var outs = [Data](repeating: Data(), count: 3)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 3) { i in
      let d = (try? export(url, xpath: xpaths[i])) ?? Data()
      lock.lock(); outs[i] = d; lock.unlock()
    }
    guard let tp = try? XCTable(xml: outs[0]), tp.schema == "time-profile" else { throw HostError.harness("no time-profile table in \(url.path) (record it with --template time)") }
    let sp = try? XCTable(xml: outs[1])
    let toc = String(decoding: outs[2], as: UTF8.self)
    let os = firstMatch(#"<device [^>]*os-version="([^"]*)""#, in: toc)
    let proc = process ?? firstMatch(#"<process type="attached"[^>]* name="([^"]*)""#, in: toc)
    let s = MainThreadSamples(timeProfile: tp, process: proc)
    let steps = per == "run" ? [] : (sp.map { StepInterval.fromSignposts($0) } ?? [])
    let trees = StepTrees(samples: s, steps: steps)
    if per == "run" { return DiffInput(side: DiffSide(trace: url.path, os: os, steps: 1, stepSource: "run", samples: s.count, sampleIntervalMs: s.sampleIntervalMs), tree: trees.whole) }
    if steps.isEmpty {
      let n = max(1, inProcessSteps ?? 1)
      return DiffInput(side: DiffSide(trace: url.path, os: os, steps: n, stepSource: inProcessSteps == nil ? "none" : "inProcess", samples: s.count, sampleIntervalMs: s.sampleIntervalMs),
                       tree: trees.whole, notes: ["no `step` signposts in the trace: the whole recording ÷ \(n) step\(n == 1 ? "" : "s") (settling and idle time included)"])
    }
    let outside = Double(trees.outside.v) * s.sampleIntervalMs
    return DiffInput(side: DiffSide(trace: url.path, os: os, steps: steps.count, stepSource: "signpost", samples: s.count, sampleIntervalMs: s.sampleIntervalMs), tree: trees.inSteps,
                     notes: ["\(trees.inSteps.v) of \(s.count) main-thread samples inside \(steps.count) steps; \(Int(outside)) ms outside steps not compared"])
  }
}

/// A child's output, collected from the pipe's handler thread while the main thread waits on it.
final class LogBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
  var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
#endif

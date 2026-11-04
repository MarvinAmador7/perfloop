import Foundation
import PerfLoopKit

/// `perfloop mcp`: the loop as Model Context Protocol tools over stdio (JSON-RPC 2.0, one message per line), so a coding
/// agent (Claude Code, Codex, Cursor, …) discovers the verbs with their schemas instead of reading a CLI's help
/// (docs/BEYOND.md, rank 1).
///
/// Two things it does that a shell can't:
/// - **Jobs.** A stage that opens windows or builds (a screen, a full, a profile, a sweep) starts a job: the server runs
///   `perfloop` as its own child, keeps its output in `jobs/<id>.log` beside the store, and answers at once with the job's
///   id. `job` waits on the server's side (up to 60 s a call) and returns the state and the output's end, so an agent
///   never writes a sleep loop. Every job still running when the session ends (stdin closes, or a signal) is killed with
///   its children: nothing is left behind.
/// - **The agent's surface only.** No tool takes `--force`, `--owner`, `--guard-tolerance` or `--allow-dirty`, and no
///   value can smuggle a flag in (a value that starts with `-` is refused): what judges the agent stays the owner's.
public final class MCPServer {
  public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
  /// The `perfloop` executable each tool runs.
  public let cli: String
  /// Added to every call (`--store DIR`, `--app NAME`).
  public var baseArgs: [String]
  public var env: [String: String] = [:]
  public let jobsDir: URL
  /// The window lock local runs take (other benches on this Mac take turns with them).
  public var lock: String
  public var version = "1"

  final class Job {
    let id: String, tool: String, args: [String], log: URL, started = Date()
    let process = Process()
    var status: Int32?
    init(id: String, tool: String, args: [String], log: URL) { self.id = id; self.tool = tool; self.args = args; self.log = log }
    var running: Bool { status == nil && process.isRunning }
  }
  var jobs: [Job] = []
  /// The server of this process, for a signal handler's last act.
  public static var current: MCPServer?
  private let lockJobs = NSLock()

  public init(cli: String, baseArgs: [String] = [], jobsDir: URL, lock: String? = nil) {
    self.cli = cli; self.baseArgs = baseArgs; self.jobsDir = jobsDir
    self.lock = lock ?? FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-window.lock").path
  }

  // MARK: tools

  enum Kind { case now, job }
  struct Tool {
    var name: String
    var description: String
    var properties: [String: JSONValue]
    var required: [String]
    var kind: Kind
    /// The CLI's arguments from the call's (validated) arguments.
    var args: ([String: JSONValue]) throws -> [String]
  }

  static func prop(_ type: String, _ d: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(["type": .string(type), "description": .string(d)].merging(extra) { $1 })
  }
  static let runnerProp = prop("string", "Where windows open: \"local\" (this Mac now, holding the window lock; the default), \"local-idle\" (this Mac once nobody has touched it for 120 s; a rep is redone if someone does), or \"ssh://user@host\" (a spare Mac). Results never mix runners.")

  /// Every tool, in the order an agent meets them.
  lazy var tools: [Tool] = [
    Tool(name: "status", description: "The champion, open experiments and what each needs next, and a `stop:` line when the stopping rules say the session is over. Start here.",
         properties: ["id": Self.prop("string", "An experiment id: its explain instead")], required: [], kind: .now) { a in
      try ["exp", "status"] + Self.opt(a, "id", Self.id) },
    Tool(name: "explain", description: "An experiment's explain.txt: verdict, numbers, where the time went (stacks, causes), hypotheses, and the next command.",
         properties: ["id": Self.prop("string", "Experiment id, e.g. 0007")], required: ["id"], kind: .now) { a in try ["explain", "exp/" + Self.id(Self.req(a, "id"))] },
    Tool(name: "suggest", description: "Ranked hypotheses for the next experiment from what the loop recorded (cause records, stacks, profiles, sweeps), each with its evidence and the share of the objective it could remove. Leads to check, not conclusions.",
         properties: ["target": Self.prop("string", "champion (default) or exp/ID")], required: [], kind: .now) { a in
      try ["suggest"] + Self.opt(a, "target", Self.target) },
    Tool(name: "ledger", description: "Every state change of every experiment, oldest first: what was tried, by whom, where, with what result.", properties: [:], required: [], kind: .now) { _ in ["ledger"] },
    Tool(name: "champion", description: "The build to beat and its chain back to a merged commit.", properties: [:], required: [], kind: .now) { _ in ["champion"] },
    Tool(name: "doctor", description: "What would make this Mac's numbers untrustworthy now (screen lock, someone using it, load, disk, xctrace), and with a bench, the adapter's contract.",
         properties: ["bench": Self.prop("string", "Path to a bench executable to check too")], required: [], kind: .now) { a in try ["doctor"] + Self.opt(a, "bench", Self.path, flag: "--bench") },
    Tool(name: "describe", description: "A bench's manifest: scenarios, objectives, guards, fixtures, knobs.",
         properties: ["bench": Self.prop("string", "Path to the bench executable")], required: ["bench"], kind: .now) { a in try ["describe", "--bench", Self.path(Self.req(a, "bench"))] },
    Tool(name: "gestures", description: "Recorded and synthetic gestures a gesture-replay scenario can take.", properties: [:], required: [], kind: .now) { _ in ["gestures", "list"] },
    Tool(name: "new_experiment", description: "A candidate against the champion, then its screen (3 interleaved pairs; opens windows). One idea per experiment, said in one sentence that names the cost and why the change removes it; commit first (the bench is stamped with its commit). Returns a job.",
         properties: ["hypothesis": Self.prop("string", "One sentence: the cost and why the change removes it"),
                      "bench": Self.prop("string", "The candidate's bench executable (built), or what build_cmd produces"),
                      "build_cmd": Self.prop("string", "A command that builds the candidate's bench (run in the current directory)"),
                      "knobs": Self.prop("string", "k=v,k=v: an idea the app already has as a knob (no rebuild)"),
                      "scenario": Self.prop("string", "Default: the champion's"), "fixture": Self.prop("string", "Default: the champion's"),
                      "behaviour_change": Self.prop("boolean", "The change alters what the user sees or can do: promotion then needs the owner"),
                      "screen": Self.prop("boolean", "Screen it now (default true)"), "runner": Self.runnerProp],
         required: ["hypothesis"], kind: .job) { [unowned self] a in
      var x = try ["exp", "new", Self.text(Self.req(a, "hypothesis"))]
      x += try Self.opt(a, "bench", Self.path, flag: "--bench") + Self.opt(a, "build_cmd", { $0 }, flag: "--build-cmd") + Self.opt(a, "knobs", Self.knobs, flag: "--knobs")
      x += try Self.opt(a, "scenario", Self.name, flag: "--scenario") + Self.opt(a, "fixture", Self.name, flag: "--fixture")
      if a["behaviour_change"]?.bool == true { x.append("--behaviour-change") }
      if a["screen"]?.bool == false { x.append("--no-screen") } else { x += try self.runner(a) }
      return x },
    Tool(name: "screen", description: "3 interleaved pairs, champion vs candidate: promising | rejected. Opens windows. Returns a job.",
         properties: ["id": Self.prop("string", "Experiment id"), "runner": Self.runnerProp], required: ["id"], kind: .job) { [unowned self] a in
      try ["exp", "screen", Self.id(Self.req(a, "id"))] + self.runner(a) },
    Tool(name: "full", description: "5 + 5 interleaved pairs (extended to 8 + 8 and 10 + 10 while undecided), frame guards, the second fixture: won | lost | needsReview. Opens windows. Returns a job.",
         properties: ["id": Self.prop("string", "Experiment id"), "runner": Self.runnerProp], required: ["id"], kind: .job) { [unowned self] a in
      try ["exp", "full", Self.id(Self.req(a, "id"))] + self.runner(a) },
    Tool(name: "promote", description: "A won experiment becomes the champion (refused for a dirty build, a declared behaviour change, or a guard that asks the owner). Then open a PR with its explain.txt and patch.",
         properties: ["id": Self.prop("string", "Experiment id"), "pr": Self.prop("string", "The PR's URL, when there is one")], required: ["id"], kind: .now) { a in
      try ["exp", "promote", Self.id(Self.req(a, "id"))] + Self.opt(a, "pr", Self.text, flag: "--pr") },
    Tool(name: "abandon", description: "Ends an experiment without a verdict (an idea dropped).", properties: ["id": Self.prop("string", "Experiment id"), "note": Self.prop("string", "Why")],
         required: ["id"], kind: .now) { a in try ["exp", "abandon", Self.id(Self.req(a, "id"))] + Self.opt(a, "note", Self.text, flag: "--note") },
    Tool(name: "guards", description: "The correctness guards alone: a fresh pair of the experiment's scenario and the isolation scenarios. Opens windows. Returns a job.",
         properties: ["id": Self.prop("string", "Experiment id"), "runner": Self.runnerProp], required: ["id"], kind: .job) { [unowned self] a in
      try ["guards", "--exp", Self.id(Self.req(a, "id"))] + self.runner(a, allowSSH: false) },
    Tool(name: "profile", description: "The champion or an experiment under xctrace (opens a window on this Mac): call trees per step, hitches, hangs. Kept in the store; never an objective. Returns a job.",
         properties: ["target": Self.prop("string", "champion or exp/ID"), "template": Self.prop("string", "time (default), hitches or swiftui", ["enum": .array(["time", "hitches", "swiftui"].map(JSONValue.string))]),
                      "scenario": Self.prop("string", "Default: the experiment's")], required: ["target"], kind: .job) { [unowned self] a in
      try ["profile", Self.target(Self.req(a, "target"))] + Self.opt(a, "template", Self.name, flag: "--template") + Self.opt(a, "scenario", Self.name, flag: "--scenario")
        + self.runner(a, allowSSH: false) },
    Tool(name: "diff", description: "What grew and shrank between two profiles, ms per step on the main thread: champion vs exp/ID (their newest profiles) or two profile files. Refuses profiles of other builds.",
         properties: ["a": Self.prop("string", "champion, exp/ID or a profile path"), "b": Self.prop("string", "champion, exp/ID or a profile path")], required: ["a", "b"], kind: .now) { a in
      try ["diff", Self.targetOrPath(Self.req(a, "a")), Self.targetOrPath(Self.req(a, "b"))] },
    Tool(name: "sweep", description: "A cost curve: the objective over a grid of fixture parameters or knobs, with fitted slopes and where the curve crosses the frame budget. Opens windows. Returns a job.",
         properties: ["scenario": Self.prop("string", "Scenario"), "set": Self.prop("array", "NAME=4..64/4 or NAME=a,b per axis", ["items": .object(["type": .string("string")])]),
                      "bench": Self.prop("string", "Default: the champion's"), "reps": Self.prop("integer", "Reps per point (default 1)")], required: ["scenario", "set"], kind: .job) { [unowned self] a in
      var x = try ["sweep", Self.name(Self.req(a, "scenario"))]
      for s in a["set"]?.array?.compactMap(\.string) ?? [] { x += ["--set", try Self.text(s)] }
      x += try Self.opt(a, "bench", Self.path, flag: "--bench")
      if let r = a["reps"]?.double { x += ["--reps", String(Int(r))] }
      return x + ["--lock", self.lock] },
    Tool(name: "queue_add", description: "Queues an experiment's stages for a runner (the owner's `queue run` takes them, e.g. overnight on a spare Mac).",
         properties: ["id": Self.prop("string", "Experiment id"), "stage": Self.prop("string", "auto (default: the screen, then the full when promising), screen or full"),
                      "runner": Self.prop("string", "ssh://user@host or local")], required: ["id"], kind: .now) { a in
      try ["queue", "add", Self.id(Self.req(a, "id"))] + Self.opt(a, "stage", Self.name, flag: "--stage") + Self.opt(a, "runner", Self.runnerSpec, flag: "--runner") },
    Tool(name: "job", description: "A job's state and the end of its output. Waits up to wait_s seconds (max 60) for it to finish first, so poll it instead of sleeping.",
         properties: ["id": Self.prop("string", "Job id (j1, j2, …)"), "wait_s": Self.prop("number", "Seconds to wait for the job to end (0–60, default 30)")], required: ["id"], kind: .now) { _ in [] },
    Tool(name: "jobs", description: "Every job of this session and its state.", properties: [:], required: [], kind: .now) { _ in [] },
    Tool(name: "cancel_job", description: "Stops a running job and the windows it opened; its stage resumes where it stopped next time.",
         properties: ["id": Self.prop("string", "Job id")], required: ["id"], kind: .now) { _ in [] },
  ]

  // MARK: argument checks

  struct Refused: Error, CustomStringConvertible { var description: String }
  static func req(_ a: [String: JSONValue], _ k: String) throws -> String {
    guard let v = a[k]?.string ?? a[k]?.double.map({ String(Int($0)) }), !v.isEmpty else { throw Refused(description: "missing argument '\(k)'") }
    return v
  }
  static func opt(_ a: [String: JSONValue], _ k: String, _ check: (String) throws -> String, flag: String? = nil) throws -> [String] {
    guard let v = a[k]?.string, !v.isEmpty else { return [] }
    return (flag.map { [$0] } ?? []) + [try check(v)]
  }
  /// No value may read as a flag: the owner's flags aren't tools, and can't come in through a value.
  static func text(_ s: String) throws -> String {
    guard !s.hasPrefix("-") else { throw Refused(description: "'\(s)': a value can't start with '-'") }
    return s
  }
  static func id(_ s: String) throws -> String {
    let t = s.hasPrefix("exp/") ? String(s.dropFirst(4)) : s
    guard !t.isEmpty, t.count <= 8, t.allSatisfy(\.isNumber) else { throw Refused(description: "'\(s)' isn't an experiment id (digits, e.g. 0007)") }
    return t
  }
  static func target(_ s: String) throws -> String {
    if s == "champion" { return s }
    return "exp/" + (try id(s))
  }
  static func targetOrPath(_ s: String) throws -> String { s == "champion" || s.hasPrefix("exp/") ? try target(s) : try path(s) }
  static func path(_ s: String) throws -> String { try text(s) }
  static func name(_ s: String) throws -> String {
    guard !s.hasPrefix("-"), s.allSatisfy({ $0.isLetter || $0.isNumber || "._-@=,:".contains($0) }) else { throw Refused(description: "'\(s)' isn't a name") }
    return s
  }
  static func knobs(_ s: String) throws -> String {
    let parts = s.split(separator: ",")
    guard !s.hasPrefix("-"), !parts.isEmpty, parts.allSatisfy({ $0.split(separator: "=", maxSplits: 1).count == 2 }) else { throw Refused(description: "knobs are k=v,k=v, not '\(s)'") }
    return s
  }
  static func runnerSpec(_ s: String) throws -> String {
    guard s == "local" || (s.hasPrefix("ssh://") && RunnerSpec(s) != nil) else { throw Refused(description: "runner '\(s)': local or ssh://user@host") }
    return s
  }
  func runner(_ a: [String: JSONValue], allowSSH: Bool = true) throws -> [String] {
    switch a["runner"]?.string ?? "local" {
    case "local": return ["--runner", "local", "--lock", lock]
    case "local-idle": return ["--runner", "local", "--idle", "120", "--lock", lock]
    case let s where allowSSH && s.hasPrefix("ssh://"): return ["--runner", try Self.runnerSpec(s)]
    case let s: throw Refused(description: "runner '\(s)': local, local-idle\(allowSSH ? " or ssh://user@host" : " (this one runs on this Mac)")")
    }
  }

  // MARK: JSON-RPC

  /// One message in, its response out (nil for a notification).
  public func handle(_ line: String) -> String? {
    guard let req = try? PLJSON.decode(JSONValue.self, from: Data(line.utf8)), case .object = req else {
      return Self.error(id: .null, code: -32700, "parse error")
    }
    let id = req["id"]
    let method = req["method"]?.string ?? ""
    guard let id else { return nil }   // notifications (notifications/initialized, cancelled): nothing to answer
    switch method {
    case "initialize":
      let asked = req["params"]?["protocolVersion"]?.string ?? Self.protocolVersions[0]
      return Self.result(id: id, .object([
        "protocolVersion": .string(Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]),
        "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
        "serverInfo": .object(["name": .string("perfloop"), "version": .string(version)]),
        "instructions": .string("PerfLoop: the agent's performance loop for a native macOS app. Start with `status`, read `explain` and `suggest`, make one change per experiment, commit, then `new_experiment`; poll jobs with `job` (it waits for you). Never edit the bench, its manifest or the store. AGENTS.md in the PerfLoop repository has the rules."),
      ]))
    case "ping": return Self.result(id: id, .object([:]))
    case "tools/list":
      return Self.result(id: id, .object(["tools": .array(tools.map { t in
        .object(["name": .string(t.name), "description": .string(t.description),
                 "inputSchema": .object(["type": .string("object"), "properties": .object(t.properties), "required": .array(t.required.map(JSONValue.string)),
                                         "additionalProperties": .bool(false)])])
      })]))
    case "tools/call":
      let name = req["params"]?["name"]?.string ?? ""
      let args = req["params"]?["arguments"]?.object ?? [:]
      guard let t = tools.first(where: { $0.name == name }) else { return Self.error(id: id, code: -32602, "unknown tool '\(name)'") }
      let (text, isError) = call(t, args)
      return Self.result(id: id, .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)]))
    default:
      return Self.error(id: id, code: -32601, "method not found: \(method)")
    }
  }

  static func result(id: JSONValue, _ r: JSONValue) -> String { PLJSON.line(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": r])) }
  static func error(id: JSONValue, code: Int, _ m: String) -> String {
    PLJSON.line(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(m)])]))
  }

  func call(_ t: Tool, _ a: [String: JSONValue]) -> (String, Bool) {
    if let extra = Set(a.keys).subtracting(t.properties.keys).sorted().first { return ("unknown argument '\(extra)' for \(t.name)", true) }
    do {
      switch t.name {
      case "job": return try jobStatus(Self.req(a, "id"), wait: min(60, max(0, a["wait_s"]?.double ?? 30)))
      case "jobs": return (jobsText(), false)
      case "cancel_job": return try cancel(Self.req(a, "id"))
      default: break
      }
      let args = try t.args(a)
      if t.kind == .job { return try start(t.name, args) }
      let o = try runNow(args)
      return (o.text.isEmpty ? "(no output; exit \(o.status))" : o.text, o.status != 0)
    } catch let r as Refused { return ("refused: \(r)", true) } catch { return ("\(error)", true) }
  }

  // MARK: running the CLI

  func process(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli); p.arguments = args + baseArgs
    var e = ProcessInfo.processInfo.environment; for (k, v) in env { e[k] = v }; p.environment = e
    p.standardInput = FileHandle.nullDevice
    return p
  }

  /// A headless verb, to completion (stdout, then stderr's lines).
  func runNow(_ args: [String]) throws -> (status: Int32, text: String) {
    let p = process(args)
    let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
    try p.run()
    var e = Data()
    let g = DispatchGroup(); g.enter()
    DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); g.wait()
    let text = [String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self)].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return (p.terminationStatus, text.joined(separator: "\n"))
  }

  func start(_ tool: String, _ args: [String]) throws -> (String, Bool) {
    try FileManager.default.createDirectory(at: jobsDir, withIntermediateDirectories: true)
    lockJobs.lock(); let n = jobs.count + 1; lockJobs.unlock()
    let stamp = Clock.now().replacingOccurrences(of: ":", with: "")
    let j = Job(id: "j\(n)", tool: tool, args: args, log: jobsDir.appendingPathComponent("\(stamp)-j\(n)-\(tool).log"))
    FileManager.default.createFile(atPath: j.log.path, contents: Data("$ perfloop \(args.joined(separator: " "))\n".utf8))
    let h = try FileHandle(forWritingTo: j.log); try h.seekToEnd()
    j.process.executableURL = URL(fileURLWithPath: cli); j.process.arguments = args + baseArgs
    var e = ProcessInfo.processInfo.environment; for (k, v) in env { e[k] = v }; j.process.environment = e
    j.process.standardInput = FileHandle.nullDevice; j.process.standardOutput = h; j.process.standardError = h
    j.process.terminationHandler = { [weak j] p in j?.status = p.terminationStatus; try? h.close() }
    try j.process.run()
    lockJobs.lock(); jobs.append(j); lockJobs.unlock()
    return ("started job \(j.id) (\(tool)): perfloop \(args.joined(separator: " "))\nlog: \(j.log.path)\nnext: job \(j.id) (it waits up to 60 s for the job to end)", false)
  }

  func job(_ id: String) throws -> Job {
    lockJobs.lock(); defer { lockJobs.unlock() }
    guard let j = jobs.first(where: { $0.id == id }) else { throw Refused(description: "no job \(id) in this session (jobs: \(jobs.map(\.id).joined(separator: ", ")))") }
    return j
  }

  func jobStatus(_ id: String, wait: Double) throws -> (String, Bool) {
    let j = try job(id)
    let until = Date().addingTimeInterval(wait)
    while j.running, Date() < until { Thread.sleep(forTimeInterval: 0.2) }
    if !j.process.isRunning, j.status == nil { j.status = j.process.terminationStatus }
    let log = (try? String(contentsOf: j.log, encoding: .utf8)) ?? ""
    let tail = log.count > 6000 ? "…" + String(log.suffix(6000)) : log
    let elapsed = Int(Date().timeIntervalSince(j.started))
    let state = j.running ? "running (\(elapsed) s so far): ask again" : "finished, exit \(j.status ?? -1) after \(elapsed) s"
    return ("job \(j.id) (\(j.tool)) \(state)\n\(tail)", !j.running && (j.status ?? 0) != 0 && (j.status ?? 0) != 6 && (j.status ?? 0) != 3 && (j.status ?? 0) != 4)
  }

  func jobsText() -> String {
    lockJobs.lock(); defer { lockJobs.unlock() }
    if jobs.isEmpty { return "no jobs in this session" }
    return jobs.map { "\($0.id) \($0.tool) \($0.running ? "running" : "exit \($0.status ?? $0.process.terminationStatus)") · \($0.log.path)" }.joined(separator: "\n")
  }

  func cancel(_ id: String) throws -> (String, Bool) {
    let j = try job(id)
    guard j.running else { return ("job \(id) already ended (exit \(j.status ?? j.process.terminationStatus))", false) }
    ProcessTree.kill(j.process.processIdentifier, grace: 5)
    j.process.waitUntilExit()
    return ("job \(id) stopped; its stage resumes at the first missing pair next time", false)
  }

  /// Kills every job still running, with its children (windows included). Called when the session ends.
  public func shutdown() {
    lockJobs.lock(); let live = jobs.filter(\.running); lockJobs.unlock()
    for j in live { ProcessTree.kill(j.process.processIdentifier, grace: 3) }
  }

  /// Serves until stdin closes, then stops the jobs.
  public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
    var buffer = Data()
    while true {
      let chunk = input.availableData
      if chunk.isEmpty { break }
      buffer.append(chunk)
      while let nl = buffer.firstIndex(of: 0x0A) {
        let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...nl)
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let r = handle(line) else { continue }
        output.write(Data((r + "\n").utf8))
      }
    }
    shutdown()
  }
}

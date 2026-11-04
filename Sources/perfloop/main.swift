import Foundation
import PerfLoopKit
import PerfLoopRunner

// perfloop: the runner of an app's performance loop (docs/design/SPEC.md). It drives the app's bench adapter as a
// child (`describe`, `ab`, `run`, `diff`), keeps builds, experiments and the ledger in a store, and decides with the
// acceptance rule of SPEC §5.1. The adapter folder's PROGRAM.md is the procedure an agent follows.

let help = """
perfloop: an agent-first performance loop for native macOS apps (README.md; agents: AGENTS.md and the app's PROGRAM.md)

  doctor [--bench PATH] [--json]            what stands between this Mac and numbers that decide (screen lock, idle,
                                            load, disk, the store's place, xctrace) and, with --bench, the adapter's
                                            contract (headless): each check ok | warn | fail with its fix; exit 1 on a fail
  init --app NAME [--dir DIR] [--target NAME] [--perfloop PATH|URL] [--package]
                                            scaffold a bench for your app: Sources/<Name>Bench/main.swift (PerfLoopHost,
                                            one scenario on a placeholder view), PROGRAM.md for your agent, and the
                                            Package.swift lines to add (--package: a standalone Package.swift). Never
                                            overwrites a file
  describe --bench PATH                     the adapter's manifest (describe --json, or derived from list --json)
  store import DIR --commit SHA [--dirty] --note "…" [--exe NAME]
                                            a bench that predates the build stamp, under its sha256
  store add PATH [--exe NAME]               a stamped bench (its list --json → tool.build)
  store list | store gc [--keep N]          builds in the store; gc keeps the newest N (20), every champion, open experiments
  champion [--json]                         the champion and its parent chain back to main
  champion set BUILD [--merged] [--scenario S] [--fixture F] [--note "…"]
                                            the first champion (owner); later experiments inherit scenario and fixture
  champion merged SHA                       the champion's PR landed at SHA: the chain restarts there
  exp new "<hypothesis>" [--bench PATH | --build-cmd CMD --bench PATH | --build HASH | --knobs k=v,…]
          [--scenario S] [--fixture F] [--second-fixture F] [--set k=v] [--via ab|run]
          [--behaviour-change] [--patch FILE] [--no-screen] [--against ID]
                                            a candidate against the champion; screens it unless --no-screen
  exp status [ID]                           open experiments and what each needs next (with ID: its explain)
  exp screen ID                             3 interleaved pairs: promising | rejected
  exp full ID [--force]                     5 + 5 (→ 8 + 8 → 10 + 10 while unknown): won | lost | needsReview
  exp promote ID [--owner] [--allow-dirty] [--pr URL]
                                            the champion moves to the experiment's build
  exp abandon ID [--note "…"]
  exp replay PLAN.json [--dry-run | --go]   a past session as experiments (SPEC §6.1); --go opens windows
  guards --exp ID [--guard-tolerance X --owner]
                                            the correctness guards alone (C6): a fresh pair of the experiment's scenario
                                            and the isolation scenarios; a failure demotes it, a snapshot over tolerance
                                            asks the owner; only the owner sets a tolerance (never inside exp)
  explain exp/ID                            exp/ID/explain.txt: everything needed to decide the next step
  suggest [champion|exp/ID|RESULT.json] [--json]
                                            hypotheses for the next experiment from what was recorded (cause fan-out,
                                            repeated bodies, hot frames of ours, framework work they ask for, a profile's
                                            largest subtrees, a sweep's walls), ranked by the share they could remove
  causes RESULT.json [--json]               why bodies ran: the model mutations each step's and long stretch's bodies
                                            followed (the adapter's mutation records, CAPABILITIES.md C7)
  profile champion|exp/ID [--template time|hitches|swiftui] [--scenario S] [--fixture F] [--keep-trace] [--lock DIR] [--idle S]
                                            the build under xctrace (the adapter's `profile`; opens a window on this Mac):
                                            call trees per step, hitches, hangs; kept in the store, never an objective
  diff A B [--exp ID] [--allow-stale]       the adapter's differential call tree, ms per step: A and B are champion, exp/ID
                                            (their newest profile), profile JSONs or traces; refuses other builds' traces
  trace register TRACE --build HASH         record which build a trace was recorded on (the path only)
  ledger [--json]                           every state change, oldest first
  sweep SCENARIO --set NAME=4..64/4 [--set …] [--bench PATH] [--fixture F] [--reps N] [--dry-run] [--lock DIR] [--json]
                                            a grid over fixture parameters, knobs and params: the objective per point
                                            and fitted cost curves (perfloop.sweep/1); `perfloop sweep --help` for more
  gestures list [FILE…] [--dir DIR] [--bench PATH]
                                            recorded and synthetic gestures (perfloop.gesture/1) for a gesture-replay
                                            scenario: the store's gestures/, each --dir, the adapter's built-in ones
  session start                             the stopping rules (SPEC §5.3) count from here
  mcp [--app NAME | --store DIR] [--lock DIR]
                                            the loop as MCP tools over stdio for a coding agent (README: Agents over MCP):
                                            stages run as jobs it polls with `job`; no owner flags

runners and the queue (C10): where windowed reps run; results never mix runners
  exp screen|full ID --runner R [--idle S]  R: local (default; idle-gated only with --idle S), ssh://[user@]host[/dir],
                                            vm:tart/NAME (a macOS VM on this Mac; screens only)
  queue add ID [--stage auto|screen|full] [--runner R] [--force]
                                            auto: the screen, then the full when promising (--force: the full anyway)
  queue list [--json] | queue remove QID
  queue run --runner R [--until HH:MM] [--idle S] [--force]
                                            runs queued stages on R while it is free: local waits until nobody has
                                            touched this Mac for S s (120) and aborts a rep on input (redone); no rep
                                            starts after --until; ssh:// copies the build there and opens the window
                                            in the logged-in user's session (--launch direct: plain ssh)
  runner check R | runner clean R           the runner's machine, session and store there; clean removes that store
  ssh runner flags: --accept-new-host-key, --remote-env K=V, --launch gui|direct
  local runner flags: --lock DIR (a mkdir lock held around each rep), --busy-apps A,B, --idle-from FILE (testing)

store: --store DIR, else ${PERFLOOP_HOME:-~/.perfloop}/<app>, app from --app or $PERFLOOP_APP
exit codes  0 ok · 1 usage · 2 harness error · 6 refused (provenance, guards, owner needed)
"""

struct Args {
  var positional: [String] = []
  var flags: [String: [String]] = [:]
  static let valued: Set<String> = ["bench", "commit", "note", "exe", "keep", "scenario", "fixture", "second-fixture", "set", "via", "build-cmd", "build", "knobs",
                                    "patch", "pr", "store", "app", "exp", "against", "guard-tolerance", "dir",
                                    "runner", "idle", "until", "stage", "idle-from", "remote-env", "launch", "busy-apps", "lock", "target", "perfloop", "template", "top"]
  init(_ argv: [String]) {
    var i = 0
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("--") {
        let k = String(a.dropFirst(2))
        if Self.valued.contains(k), i + 1 < argv.count { flags[k, default: []].append(argv[i + 1]); i += 2 } else { flags[k, default: []].append("1"); i += 1 }
      } else { positional.append(a); i += 1 }
    }
  }
  func has(_ k: String) -> Bool { flags[k] != nil }
  func one(_ k: String) -> String? { flags[k]?.last }
  func all(_ k: String) -> [String] { flags[k] ?? [] }
  subscript(_ i: Int) -> String? { positional.indices.contains(i) ? positional[i] : nil }
}

func out(_ s: String) { print(s); fflush(stdout) }
func err(_ s: String) { FileHandle.standardError.write(Data(("perfloop: " + s + "\n").utf8)) }

func run(_ args: Args) throws -> Int32 {
  let json = args.has("json")
  func store(bench: String? = nil) throws -> Store {
    try Store.locate(store: args.one("store"), app: args.one("app")) {
      guard let b = bench, let exe = try? Store.executable(at: b, named: args.one("exe")) else { return nil }
      return Adapter(exe: exe.path).manifest()?.app
    }
  }
  func loop(bench: String? = nil) throws -> Loop {
    let l = Loop(store: try store(bench: bench))
    if args.has("owner") { l.by = "owner" }
    return l
  }
  func show(_ e: Experiment, _ l: Loop) { out(json ? PLJSON.encode(e) : l.explain(e)) }

  // Guard tolerances come from the champion's manifest; the owner may try another one with `guards`, never an
  // experiment's verbs (C6, anti-Goodhart).
  if args[0] == "exp" && args.has("guard-tolerance") {
    throw PLError.refused("--guard-tolerance is refused inside exp: guards and their tolerances come from the champion's manifest (the owner: perfloop guards --exp ID --guard-tolerance X --owner)")
  }
  switch (args[0] ?? "help", args[1]) {
  case ("help", _), ("-h", _): out(help); return 0

  case ("init", _):
    guard let app = args.one("app") ?? args[1] else { throw PLError.usage("usage: perfloop init --app NAME [--dir DIR] [--target NAME] [--perfloop PATH|URL] [--package]") }
    let dir = URL(fileURLWithPath: Store.tilde(args.one("dir") ?? FileManager.default.currentDirectoryPath)).standardizedFileURL
    var dep = args.one("perfloop")
    if dep == nil, let root = Scaffold.packageRoot(of: CommandLine.arguments[0]) { dep = Scaffold.relativePath(from: dir, to: root) }
    guard let d = dep else { throw PLError.usage("where is the PerfLoop package? pass --perfloop PATH (a checkout of the perfloop repository) or a git URL") }
    var sc = Scaffold(app: app, dir: dir, target: args.one("target"), perfloop: d)
    sc.package = args.has("package")
    let w = try sc.write()
    out((w.files.map { "wrote " + $0 } + ["", w.next]).joined(separator: "\n")); return 0

  case ("doctor", _):
    var d = Doctor()
    let bench = args.one("bench") ?? args[1]
    var probe = MachineProbe()
    if let f = args.one("idle-from") ?? ProcessInfo.processInfo.environment["PERFLOOP_IDLE_FROM"] { probe.idle = FileIdleSource(path: f) }
    d.checkMachine(store: (try? store(bench: bench))?.root, probe: probe)
    if let b = bench {
      let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-doctor-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: scratch) }
      d.checkBench(b, exe: args.one("exe"), scratch: scratch)
    }
    let r = Doctor.Report(lines: d.lines)
    out(json ? PLJSON.encode(r) : r.text)
    return r.ok ? 0 : 1

  case ("describe", _):
    guard let b = args.one("bench") ?? args[1] else { throw PLError.usage("usage: perfloop describe --bench PATH") }
    let a = Adapter(exe: try Store.executable(at: b, named: args.one("exe")).path)
    if let raw = a.describeRaw() { out(raw.trimmingCharacters(in: .whitespacesAndNewlines)); return 0 }
    guard let m = a.manifest() else { throw PLError.harness("\(a.exe) has neither describe --json nor list --json") }
    err("\(a.exe) has no `describe`: manifest derived from `list --json` (source: list)")
    out(PLJSON.encode(m)); return 0

  case ("store", "import"):
    guard let dir = args[2], let commit = args.one("commit") else { throw PLError.usage("usage: perfloop store import DIR --commit SHA [--dirty] --note \"…\"") }
    let e = try store(bench: dir).importBench(dir, exe: args.one("exe"), commit: commit, dirty: args.has("dirty"), note: args.one("note"))
    out(json ? PLJSON.encode(e.build) : "imported \(e.build.hash ?? "?") [\(e.build.line)] → \(e.dir.path)"); return 0
  case ("store", "add"):
    guard let p = args[2] else { throw PLError.usage("usage: perfloop store add PATH") }
    let s = try store(bench: p)
    let e = try s.add(p, exe: args.one("exe"))
    let removed = s.gc()
    out(json ? PLJSON.encode(e.build) : "added \(e.build.hash ?? "?") [\(e.build.line)] → \(e.dir.path)" + (removed.isEmpty ? "" : "\ngc: removed \(removed.count) old build(s)")); return 0
  case ("store", "list"):
    let s = try store()
    let es = s.entries()
    if json { out(PLJSON.encode(es.map(\.build))) } else {
      let champ = s.champion()?.build.hash
      for e in es { out("\(Build.short(e.build.hash ?? "")) \(e.build.line)\(e.build.hash == champ ? " · champion" : "")\(e.build.note.map { " · \($0)" } ?? "")") }
      if es.isEmpty { out("no builds in \(s.root.path)") }
    }
    return 0
  case ("store", "gc"):
    let removed = try store().gc(keep: args.one("keep").flatMap(Int.init) ?? 20)
    out("gc: removed \(removed.count) build(s)" + removed.map { "\n  " + $0 }.joined()); return 0

  case ("champion", "set"):
    guard let b = args[2] else { throw PLError.usage("usage: perfloop champion set BUILD [--merged]") }
    let c = try loop().setChampion(build: b, merged: args.has("merged"), scenario: args.one("scenario"), fixture: args.one("fixture"), note: args.one("note"))
    out(json ? PLJSON.encode(c) : "champion \(c.experiment) [\(c.build.line)], chain \(c.chain)"); return 0
  case ("champion", "merged"):
    guard let sha = args[2] else { throw PLError.usage("usage: perfloop champion merged SHA") }
    let c = try loop().markMerged(commit: sha)
    out(json ? PLJSON.encode(c) : "champion \(c.experiment) merged at \(sha)"); return 0
  case ("champion", _):
    let s = try store()
    guard let c = s.champion() else { throw PLError.usage("no champion yet: perfloop champion set BUILD --merged") }
    if json { out(PLJSON.encode(c)); return 0 }
    out("champion \(c.experiment) since \(c.since) [\(c.build.line)]")
    out("  \(c.merged ? "merged" : "unmerged"), chain \(c.chain)")
    for (k, v) in c.objectives.sorted(by: { $0.key < $1.key }) { out("  \(k): \(v)") }
    if let k = c.knobs { out("  knob debt: \(Adapter.knobString(k))") }
    return 0

  case ("exp", "new"):
    guard let h = args[2] else { throw PLError.usage("usage: perfloop exp new \"<hypothesis>\" --bench PATH") }
    var o = Loop.NewOptions(hypothesis: h)
    o.bench = args.one("bench"); o.exe = args.one("exe"); o.buildCmd = args.one("build-cmd"); o.build = args.one("build")
    o.scenario = args.one("scenario"); o.fixture = args.one("fixture"); o.secondFixture = args.one("second-fixture")
    o.knobs = args.all("knobs").reduce(into: [:]) { $0.merge(Adapter.knobs($1)) { $1 } }
    o.params = args.all("set").reduce(into: [:]) { d, kv in let p = kv.split(separator: "=", maxSplits: 1).map(String.init); if p.count == 2 { d[p[0]] = p[1] } }
    o.behaviourChange = args.has("behaviour-change") || args.has("behavior-change"); o.via = args.one("via"); o.patch = args.one("patch")
    o.screen = !args.has("no-screen"); o.against = args.one("against")
    let l = try loop(bench: o.bench); try useRunner(l, args, gatedByDefault: false); defer { l.runner.close() }
    show(try l.new(o), l); return 0
  case ("exp", "status"):
    let l = try loop()
    if let id = args[2] { show(try l.store.experiment(id), l) } else { out(json ? PLJSON.encode(l.store.experiments().filter { !$0.state.terminal }) : l.status()) }
    return 0
  case ("exp", "screen"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop exp screen ID") }
    let l = try loop(); try useRunner(l, args, gatedByDefault: false); defer { l.runner.close() }
    show(try l.screen(id), l); return 0
  case ("exp", "full"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop exp full ID") }
    let l = try loop(); try useRunner(l, args, gatedByDefault: false); defer { l.runner.close() }
    show(try l.full(id, force: args.has("force")), l); return 0
  case ("exp", "promote"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop exp promote ID [--owner]") }
    var o = Loop.PromoteOptions(); o.owner = args.has("owner"); o.allowDirty = args.has("allow-dirty"); o.pr = args.one("pr")
    let l = try loop(); show(try l.promote(id, o), l); return 0
  case ("exp", "abandon"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop exp abandon ID") }
    let l = try loop(); show(try l.abandon(id, note: args.one("note")), l); return 0
  case ("exp", "replay"):
    guard let p = args[2] else { throw PLError.usage("usage: perfloop exp replay PLAN.json --dry-run") }
    let plan = try PLJSON.read(ReplayPlan.self, path: p)
    if !args.has("go") {
      if !args.has("dry-run") { err("the replay opens windows: printing the plan (--dry-run); --go runs it") }
      out(plan.dryRun(exists: { FileManager.default.fileExists(atPath: $0) }, size: { dir in
        (try? Store.executable(at: dir)).flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int64 }
      }).trimmingCharacters(in: .newlines))
      return 0
    }
    let l = Loop(store: try Store.locate(store: args.one("store"), app: plan.app))
    let r = try l.replay(plan)
    r.lines.forEach(out)
    out("replay: \(r.mismatches == 0 ? "every step as expected" : "\(r.mismatches) step(s) not as expected")")
    return r.mismatches == 0 ? 0 : 4

  case ("queue", "add"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop queue add ID [--stage auto|screen|full] [--runner R]") }
    let it = try loop().queueAdd(id, stage: args.one("stage") ?? "auto", runner: args.one("runner"), note: args.one("note"), force: args.has("force"))
    out("queued \(it.id): exp \(it.experiment) \(it.stage)\(it.force ? " --force" : "") on \(it.runner ?? "any runner")"); return 0
  case ("queue", "list"), ("queue", nil):
    let items = try loop().queue.items().filter { args.has("all") || $0.state != "removed" }
    out(json ? PLJSON.encode(items.map { ["id": $0.id, "experiment": $0.experiment, "stage": $0.stage, "runner": $0.runner ?? "", "state": $0.state, "addedAt": $0.addedAt, "note": $0.note ?? "", "lastWait": $0.lastWait ?? "", "ranOn": $0.ranOn ?? ""] }) : Queue.text(items))
    return 0
  case ("queue", "remove"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop queue remove QID") }
    try loop().queueRemove(id); out("removed \(id)"); return 0
  case ("queue", "run"):
    guard let spec = args.one("runner") else { throw PLError.usage("usage: perfloop queue run --runner R [--until HH:MM] [--idle S] [--force]") }
    var until: Date?
    if let u = args.one("until") { guard let d = Until.parse(u) else { throw PLError.usage("--until HH:MM (24 h)") }; until = d }
    let l = try loop()
    let r = try Runners.make(spec, store: l.store, options: runnerOptions(args, gatedByDefault: true))
    r.log = { err($0) }
    trapSignals()
    let res = try l.queueRun(on: r, until: until)
    res.lines.forEach(out)
    if let s = res.stopped { out("stopped: \(s)") }
    return 0
  case ("runner", "check"), ("runner", "clean"):
    guard let spec = args[2] else { throw PLError.usage("usage: perfloop runner check|clean R") }
    let r = try Runners.make(spec, store: try store(), options: runnerOptions(args, gatedByDefault: false))
    defer { r.close() }
    if args[1] == "clean" {
      if let v = r as? VMRunner { out(try v.clean()); return 0 }
      guard let s = r as? SSHRunner else { out("\(r.name): nothing to clean (the store is this one)"); return 0 }
      out(try s.clean()); return 0
    }
    if let s = r as? SSHRunner { try s.check().forEach(out); return 0 }
    if let v = r as? VMRunner { try v.check().forEach(out); return 0 }
    let i = try r.identity()
    out("\(i.line), macOS \(i.os ?? "?")")
    if let lr = r as? LocalRunner, let g = lr.gate {
      let reading = lr.idle.read()
      out("idle: \(reading.idle.map { "\(Int($0)) s" } ?? "unknown")\(reading.frontmost.map { ", frontmost \($0)" } ?? "")\(reading.locked == true ? ", screen locked" : "")")
      out(g.wait(reading).map { "would wait: " + $0.text(threshold: g.threshold) } ?? "would start a rep now (idle ≥ \(Int(g.threshold)) s)")
    }
    return 0

  case ("sweep", _): return try SweepCommand.run(Array(CommandLine.arguments.dropFirst(2)))
  case ("mcp", _):
    // The loop as MCP tools over stdio (MCPServer.swift); each tool runs this executable as a child.
    let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var base: [String] = []
    if let s = args.one("store") { base += ["--store", s] }
    if let a = args.one("app") { base += ["--app", a] }
    let jobs = ((try? store())?.root ?? FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-mcp")).appendingPathComponent("jobs")
    let server = MCPServer(cli: exe, baseArgs: base, jobsDir: jobs, lock: args.one("lock"))
    for s in [SIGINT, SIGTERM, SIGHUP] { signal(s) { sig in MCPServer.current?.shutdown(); exit(128 + sig) } }
    MCPServer.current = server
    server.serve()
    return 0
  case ("gestures", _): return try GesturesCommand.run(args)
  case ("guards", _):
    guard let id = args.one("exp") ?? args[1] else { throw PLError.usage("usage: perfloop guards --exp ID [--guard-tolerance X --owner]") }
    var tol: Double?
    if let t = args.one("guard-tolerance") { guard let x = Double(t), x >= 0 else { throw PLError.usage("--guard-tolerance takes a share of pixels, e.g. 0.01") }; tol = x }
    let l = try loop(); try useRunner(l, args, gatedByDefault: false); defer { l.runner.close() }
    let (e, r) = try l.guards(id, tolerance: tol)
    if json { out(PLJSON.encode(r)) } else {
      out("guards for exp \(e.id) (\(e.scenario) on \(e.fixture))\(r.override.map { ", \($0)" } ?? ""): \(r.pass ? "PASS" : r.failures.isEmpty ? "NEEDS REVIEW" : "FAIL") → \(e.state.rawValue)")
      Explain.guardLines(Stage(metric: "-", pairs: [r.pair], verdict: "-")).forEach(out)
      for i in r.isolation { out("  isolation \(i.scenario): \(i.pass ? "holds" : i.failures.joined(separator: "; "))") }
      for f in r.failures + r.reviews { out("  · " + f) }
    }
    return r.pass ? 0 : 6

  case ("explain", _):
    guard let id = args[1] else { throw PLError.usage("usage: perfloop explain exp/ID") }
    if SweepCommand.isSweep(id) { out(Sweep.text(try SweepCommand.read(id))); return 0 }
    let l = try loop(); out(l.explain(try l.store.experiment(id)).trimmingCharacters(in: .newlines)); return 0

  case ("causes", _):
    guard let p = args[1] else { throw PLError.usage("usage: perfloop causes RESULT.json [--json]") }
    let v = try PLJSON.read(JSONValue.self, path: p)
    if json {
      guard let t = CauseTable.table(v) else { throw PLError.usage("\(p): no causes recorded in this result") }
      out(PLJSON.encode(t))
    } else { out(CauseTable.text(v)) }
    return 0

  case ("suggest", _):
    let t = args[1] ?? "champion"
    // A result file needs no store.
    let d = Loop.isProfileTarget(t) ? try loop().suggest(t) : Suggest.make(result: try PLJSON.read(JSONValue.self, path: t), sources: [t])
    out(json ? PLJSON.encode(d) : Suggest.text(d, top: args.one("top").flatMap(Int.init) ?? 6)); return 0
  case ("profile", _):
    guard let t = args[1] else { throw PLError.usage("usage: perfloop profile champion|exp/ID [--template time|hitches|swiftui] [--scenario S] [--fixture F] [--keep-trace]") }
    let l = try loop()
    if args.has("runner") || args.has("idle") || args.has("lock") {
      var o = try runnerOptions(args, gatedByDefault: false); if args.one("runner") == nil && !args.has("idle") { o.force = true }
      l.runner = try Runners.make(args.one("runner") ?? "local", store: l.store, options: o); l.runner.log = { err($0) }; trapSignals()
    }
    let r = try l.profile(t, template: args.one("template") ?? "time", scenario: args.one("scenario"), fixture: args.one("fixture"), keepTrace: args.has("keep-trace"))
    out(json ? PLJSON.encode(r.doc) : r.doc.text + "\nprofile: \(r.path)\nnext: perfloop diff champion exp/ID (once both have a profile)"); return 0
  case ("diff", _):
    guard let a = args[1], let b = args[2] else { throw PLError.usage("usage: perfloop diff A B [--exp ID] [--allow-stale]") }
    let raw = try loop().diff(a, b, exp: args.one("exp"), allowStale: args.has("allow-stale"))
    // The adapter answers in JSON; a perfloop.diff/1 is printed as text unless --json (another schema as it came).
    if !json, let d = try? PLJSON.decode(DiffResult.self, from: Data(raw.utf8)) { out(Explain.diffText(d)) } else { out(raw.trimmingCharacters(in: .newlines)) }
    return 0
  case ("trace", "register"):
    guard let t = args[2], let b = args.one("build") else { throw PLError.usage("usage: perfloop trace register TRACE --build HASH") }
    try loop().register(trace: t, build: b); out("registered \(t)"); return 0

  case ("ledger", _):
    let es = try store().ledger.entries()
    if json { out(PLJSON.encode(es)); return 0 }
    for e in es {
      var line = "\(e.at) \(e.experiment) \(e.state.padding(toLength: 11, withPad: " ", startingAt: 0)) by \(e.by)"
      if let r = e.runner { line += " on \(r)\(e.machine.map { " (\($0))" } ?? "")" }
      if let o = e.objective { line += " · \(o.before.map { String($0) } ?? "-") → \(o.after.map { String($0) } ?? "-")" }
      if let n = e.note { line += " · \(n)" }
      out(line)
    }
    return 0
  case ("session", "start"):
    try store().ledger.append(LedgerEntry(experiment: "-", state: "session", by: args.has("owner") ? "owner" : "agent", note: args.one("note")))
    out("session started"); return 0

  default:
    throw PLError.usage("unknown command '\(args.positional.joined(separator: " "))'\n\n" + help)
  }
}

/// The runner flags (C10). `exp screen/full` run ungated unless --idle is given; `queue run --runner local` is gated
/// (--idle 120) unless --force.
func runnerOptions(_ args: Args, gatedByDefault: Bool) throws -> RunnerOptions {
  var o = RunnerOptions()
  if let i = args.one("idle") { guard let x = Double(i), x >= 0 else { throw PLError.usage("--idle takes seconds") }; o.idle = x }
  o.force = args.has("force") || (!gatedByDefault && o.idle == nil)
  o.busyApps = args.one("busy-apps").map { $0.split(separator: ",").map(String.init) }
  o.idleFrom = args.one("idle-from") ?? ProcessInfo.processInfo.environment["PERFLOOP_IDLE_FROM"]
  o.acceptNewHostKey = args.has("accept-new-host-key")
  o.launch = args.one("launch")
  o.lock = args.one("lock")
  for kv in args.all("remote-env") { let p = kv.split(separator: "=", maxSplits: 1).map(String.init); if p.count == 2 { o.remoteEnv[p[0]] = p[1] } }
  return o
}

func useRunner(_ l: Loop, _ args: Args, gatedByDefault: Bool) throws {
  guard let spec = args.one("runner") ?? (args.has("idle") ? "local" : nil) else { return }
  let r = try Runners.make(spec, store: l.store, options: runnerOptions(args, gatedByDefault: gatedByDefault))
  r.log = { err($0) }
  l.runner = r
  trapSignals()
}

/// ^C or a kill during a rep: take the bench's windows down with us.
func trapSignals() {
  for s in [SIGINT, SIGTERM, SIGHUP] { signal(s) { sig in Child.killAll(); exit(128 + sig) } }
}

do { exit(try run(Args(Array(CommandLine.arguments.dropFirst())))) }
catch let e as PLError { err(e.description); exit(e.code) }
catch { err("\(error)"); exit(2) }

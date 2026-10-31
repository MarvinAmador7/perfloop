import Foundation
import PerfLoopKit
import PerfLoopRunner

// perfloop: the runner of an app's performance loop (design/perf-loop/SPEC.md). It drives the app's bench adapter as a
// child (`describe`, `ab`, `run`, `diff`), keeps builds, experiments and the ledger in a store, and decides with the
// acceptance rule of SPEC §5.1. The adapter folder's PROGRAM.md is the procedure an agent follows.

let help = """
perfloop: an agent-first performance loop (design/perf-loop/SPEC.md; the adapter's PROGRAM.md is the procedure)

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
  causes RESULT.json [--json]               why bodies ran: the model mutations each step's and long stretch's bodies
                                            followed (the adapter's mutation records, CAPABILITIES.md C7)
  diff A B [--exp ID] [--allow-stale]       the adapter's differential call tree; refuses traces of other builds
  trace register TRACE --build HASH         record which build a trace was recorded on (the path only)
  ledger [--json]                           every state change, oldest first
  sweep SCENARIO --set NAME=4..64/4 [--set …] [--bench PATH] [--fixture F] [--reps N] [--dry-run] [--lock DIR] [--json]
                                            a grid over fixture parameters, knobs and params: the objective per point
                                            and fitted cost curves (perfloop.sweep/1); `perfloop sweep --help` for more
  session start                             the stopping rules (SPEC §5.3) count from here

store: --store DIR, else ${PERFLOOP_HOME:-~/.perfloop}/<app>, app from --app or $PERFLOOP_APP
exit codes  0 ok · 1 usage · 2 harness error · 6 refused (provenance, guards, owner needed)
"""

struct Args {
  var positional: [String] = []
  var flags: [String: [String]] = [:]
  static let valued: Set<String> = ["bench", "commit", "note", "exe", "keep", "scenario", "fixture", "second-fixture", "set", "via", "build-cmd", "build", "knobs",
                                    "patch", "pr", "store", "app", "exp", "against", "guard-tolerance"]
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
    let l = try loop(bench: o.bench)
    show(try l.new(o), l); return 0
  case ("exp", "status"):
    let l = try loop()
    if let id = args[2] { show(try l.store.experiment(id), l) } else { out(json ? PLJSON.encode(l.store.experiments().filter { !$0.state.terminal }) : l.status()) }
    return 0
  case ("exp", "screen"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop exp screen ID") }
    let l = try loop(); show(try l.screen(id), l); return 0
  case ("exp", "full"):
    guard let id = args[2] else { throw PLError.usage("usage: perfloop exp full ID") }
    let l = try loop(); show(try l.full(id, force: args.has("force")), l); return 0
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

  case ("sweep", _): return try SweepCommand.run(Array(CommandLine.arguments.dropFirst(2)))
  case ("guards", _):
    guard let id = args.one("exp") ?? args[1] else { throw PLError.usage("usage: perfloop guards --exp ID [--guard-tolerance X --owner]") }
    var tol: Double?
    if let t = args.one("guard-tolerance") { guard let x = Double(t), x >= 0 else { throw PLError.usage("--guard-tolerance takes a share of pixels, e.g. 0.01") }; tol = x }
    let l = try loop()
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

  case ("diff", _):
    guard let a = args[1], let b = args[2] else { throw PLError.usage("usage: perfloop diff A B [--exp ID] [--allow-stale]") }
    out(try loop().diff(a, b, exp: args.one("exp"), allowStale: args.has("allow-stale")).trimmingCharacters(in: .newlines)); return 0
  case ("trace", "register"):
    guard let t = args[2], let b = args.one("build") else { throw PLError.usage("usage: perfloop trace register TRACE --build HASH") }
    try loop().register(trace: t, build: b); out("registered \(t)"); return 0

  case ("ledger", _):
    let es = try store().ledger.entries()
    if json { out(PLJSON.encode(es)); return 0 }
    for e in es {
      var line = "\(e.at) \(e.experiment) \(e.state.padding(toLength: 11, withPad: " ", startingAt: 0)) by \(e.by)"
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

do { exit(try run(Args(Array(CommandLine.arguments.dropFirst())))) }
catch let e as PLError { err(e.description); exit(e.code) }
catch { err("\(error)"); exit(2) }

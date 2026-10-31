import Foundation
import PerfLoopKit
import PerfLoopRunner

/// `perfloop sweep …` (C8). Parses its own flags (they are many and only its own), resolves the bench (the flag, else
/// the champion's), plans the grid, and runs it or prints it.
enum SweepCommand {
  static let help = """
  perfloop sweep SCENARIO --set NAME=VALUES [--set …] [--bench PATH] [--fixture F] [--reps N] [--objective M]
                 [--out DIR] [--dry-run] [--budget-min M] [--lock DIR] [--lock-every N] [--order shuffle|grid]
                 [--fresh] [--redo KEY] [--rep-s S] [--startup-s S] [--json]
    VALUES: 4..64/4 (inclusive, step 4) · 4..64 · 4,8,16 · ca,clip · 8 (one value: fixed, not swept)
    NAME: a knob, a parameter of the fixture (its manifest entry's `parametric`), or a scenario param; force one with
          knob:, fixture: or param:. Fixture parameters reach the adapter as --fixture NAME@k=v,k=v.
    The bench: --bench PATH, else the champion's build in the store. Results: --out DIR, else
    <store>/sweeps/<scenario>-<fixture>-<id>; the same command again resumes (finished points are kept).
    --dry-run prints the grid, the commands and an estimate; --budget-min stops starting points after M minutes;
    --lock DIR holds a mkdir lock for each point (or every N points) so window runs on one Mac take turns.
  perfloop sweep show DIR|sweep.json [--json]   a sweep's table and fits (also `perfloop explain sweep.json`)
  """

  static let valued: Set<String> = ["bench", "exe", "fixture", "set", "reps", "objective", "out", "budget-min", "lock", "lock-every", "order", "redo", "rep-s", "startup-s", "store", "app"]

  static func run(_ argv: [String]) throws -> Int32 {
    var pos: [String] = [], flags: [String: [String]] = [:]
    var i = 0
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("--") {
        let k = String(a.dropFirst(2))
        if valued.contains(k) {
          guard i + 1 < argv.count else { throw PLError.usage("--\(k) needs a value") }
          flags[k, default: []].append(argv[i + 1]); i += 2
        } else { flags[k, default: []].append("1"); i += 1 }
      } else { pos.append(a); i += 1 }
    }
    func one(_ k: String) -> String? { flags[k]?.last }
    func num(_ k: String) throws -> Double? {
      guard let s = one(k) else { return nil }
      guard let x = Double(s) else { throw PLError.usage("--\(k) wants a number, not '\(s)'") }
      return x
    }
    let json = flags["json"] != nil
    if flags["help"] != nil || pos.isEmpty { out(help); return pos.isEmpty && flags["help"] == nil ? 1 : 0 }

    if pos[0] == "show" {
      guard pos.count > 1 else { throw PLError.usage("usage: perfloop sweep show DIR|sweep.json") }
      let d = try read(pos[1])
      out(json ? PLJSON.encode(d) : Sweep.text(d)); return 0
    }

    var o = SweepRun.Options(scenario: pos[0])
    o.fixture = one("fixture"); o.sets = flags["set"] ?? []
    if let r = one("reps") { guard let n = Int(r), n > 0 else { throw PLError.usage("--reps wants a positive number") }; o.reps = n }
    o.objective = one("objective"); o.out = one("out"); o.budgetMin = try num("budget-min"); o.lock = one("lock")
    if let n = try num("lock-every") { o.lockEvery = max(1, Int(n)) }
    if let x = one("order") { guard ["shuffle", "grid"].contains(x) else { throw PLError.usage("--order is shuffle or grid") }; o.order = x }
    o.fresh = flags["fresh"] != nil; o.redo = flags["redo"] ?? []
    o.repS = try num("rep-s"); o.startupS = try num("startup-s")

    // The bench: the flag, else the champion's build.
    let exe: String
    var store: Store?
    if let b = one("bench") {
      exe = try Store.executable(at: b, named: one("exe")).path
      store = try? Store.locate(store: one("store"), app: one("app")) { Adapter(exe: exe).manifest()?.app }
    } else {
      let s = try Store.locate(store: one("store"), app: one("app"))
      guard let c = s.champion(), let h = c.build.hash else { throw PLError.usage("pass --bench PATH (no champion in \(s.root.path) to sweep)") }
      exe = try s.entry(h).executable; store = s
    }
    let manifest = Adapter(exe: exe).manifest()
    if manifest == nil { err("\(exe) printed no manifest: every --set is taken as a scenario param") }
    let home = store?.root ?? URL(fileURLWithPath: (ProcessInfo.processInfo.environment["PERFLOOP_HOME"] ?? "~/.perfloop").replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path, options: .anchored))
    let r = SweepRun()
    let plan = try r.plan(exe: exe, manifest: manifest, o, home: home)
    if flags["dry-run"] != nil { out(r.dryRun(plan, budgetMin: o.budgetMin)); return 0 }
    if plan.todo.isEmpty { err("every point is done (\(plan.dir.path)); --fresh or --redo KEY to measure again") }
    else { err("sweep: \(plan.todo.count) point(s) to measure, ≈ \(Int((plan.estimateS / 60).rounded(.up))) min\(plan.estimated ? " (a guess)" : ""); results in \(plan.dir.path)") }
    Interrupts.install()
    let d = try r.run(plan, o)
    out(json ? PLJSON.encode(d) : Sweep.text(d) + "\nresults: \(plan.dir.path)/sweep.json")
    return d.points.contains { $0.failure != nil } ? 2 : 0
  }

  /// A sweep document from its directory or file.
  static func read(_ path: String) throws -> SweepDoc {
    var isDir: ObjCBool = false
    let p = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path + "/sweep.json" : path
    do { return try PLJSON.read(SweepDoc.self, path: p) } catch { throw PLError.usage("\(p): not a perfloop.sweep/1 document (\(error))") }
  }

  /// Whether `explain`'s argument is a sweep (a sweep.json or its directory) rather than an experiment.
  static func isSweep(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let p = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path + "/sweep.json" : path
    guard let v = try? PLJSON.read(JSONValue.self, path: p) else { return false }
    return v["schema"]?.string?.hasPrefix("perfloop.sweep/") == true
  }
}

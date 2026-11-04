import Foundation
import PerfLoopKit

/// `perfloop doctor`: what stands between this Mac (and an adapter) and numbers that decide something, one line each
/// with its fix. `ok` and `warn` don't stop anything; a `fail` is something the loop would refuse or get wrong.
public struct Doctor {
  public enum Status: String, Codable, Sendable { case ok, warn, fail }
  public struct Line: Codable, Sendable, Equatable {
    public var check: String
    public var status: Status
    public var detail: String
    public var fix: String?
  }
  public struct Report: Codable, Sendable {
    public var schema = "perfloop.doctor/1"
    public var lines: [Line]
    public init(lines: [Line]) { self.lines = lines }
    public var ok: Bool { !lines.contains { $0.status == .fail } }
    public var text: String {
      (lines.map { l in "\(l.status.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(l.check): \(l.detail)" + (l.fix.map { "\n       → \($0)" } ?? "") }
       + [ok ? "doctor: nothing blocks the loop" + (lines.contains { $0.status == .warn } ? " (see the warnings)" : "") : "doctor: \(lines.filter { $0.status == .fail }.count) problem(s) to fix first"])
        .joined(separator: "\n")
    }
  }

  public var lines: [Line] = []
  public init() {}

  mutating func add(_ check: String, _ s: Status, _ detail: String, fix: String? = nil) { lines.append(Line(check: check, status: s, detail: detail, fix: fix)) }

  /// The objectives the runner knows how to read (Readings, Acceptance).
  public static let objectives: Set<String> = ["mainThreadCpuMsPerStep", "instructionsPerStep", "latencyMs", "hitchTimeRatioMsPerS"]

  /// A 1×1 PNG, to ask an adapter's `snapdiff` whether it answers (a picture against itself: exit 0).
  static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  // MARK: the adapter (ADAPTER.md), headless

  /// The headless half of the adapter contract: what `store add`, `exp new` and the guards will ask of it. Nothing
  /// here opens a window.
  public mutating func checkBench(_ path: String, exe name: String? = nil, scratch: URL) {
    let exe: URL
    do { exe = try Store.executable(at: path, named: name) } catch { add("bench", .fail, "\(error)", fix: "pass the bench executable (or the directory holding only it): swift build -c release --product <Name>Bench, then .build/release/<Name>Bench"); return }
    guard FileManager.default.isExecutableFile(atPath: exe.path) else { add("bench", .fail, "\(exe.path) is not executable"); return }
    let a = Adapter(exe: exe.path)

    // list --json and the stamp (store add)
    guard let o = try? Adapter.spawn(exe.path, ["list", "--json"], quiet: true), o.status == 0, let list = o.json else {
      add("list --json", .fail, "\(exe.lastPathComponent) list --json didn't print a JSON object with exit 0", fix: "an adapter must answer `list --json` (ADAPTER.md §1); a PerfLoopHost bench does")
      return
    }
    add("list --json", .ok, "answers")
    let hash = FileHash.sha256(file: exe.path)
    if let b = Build(json: list["tool"]?["build"]), b.stamp {
      if let h = b.hash, let real = hash, h != real {
        add("build stamp", .fail, "the bench says it is \(Build.short(h)) but the file hashes to \(Build.short(real))", fix: "report the sha256 of the running executable in tool.build.hash (PerfLoopHost does)")
      } else {
        add("build stamp", .ok, b.line)
      }
      if b.dirty { add("clean build", .warn, "built from a dirty tree (or outside git)", fix: "commit before building: experiments run on a dirty build, promotion refuses it") }
      if b.configuration != "release" { add("configuration", .warn, "a \(b.configuration) build: its numbers aren't what users get", fix: "swift build -c release") }
    } else {
      add("build stamp", .fail, "no build stamp (tool.build with stamp: true in list --json): perfloop store add refuses it",
          fix: "add the PerfLoopStamp plugin to the bench target and pass perfLoopBuildStamp to Bench(…, stamp:) (or `perfloop store import` an old binary with its commit)")
    }

    // describe --json → the manifest
    var manifest: Manifest?
    if let raw = a.describeRaw() {
      do { manifest = try PLJSON.decode(Manifest.self, from: Data(raw.utf8)); add("describe --json", .ok, "perfloop.manifest/\(manifest!.protocol)") }
      catch { add("describe --json", .fail, "prints a manifest that doesn't decode: \(error)", fix: "see SCHEMAS.md §2: app, scenarios[].name are required") }
    } else {
      manifest = Manifest.derived(fromList: list)
      add("describe --json", .warn, "no describe: the runner derives a manifest from list --json (every scenario guarded by its checks only)", fix: "answer `describe --json` with a perfloop.manifest/1 (ADAPTER.md §2)")
    }
    guard let m = manifest else { add("manifest", .fail, "no scenarios to read"); return }
    if m.protocol != 1 { add("protocol", .fail, "protocol \(m.protocol): this runner speaks 1") }

    // scenarios
    if m.scenarios.isEmpty { add("scenarios", .fail, "none", fix: "register at least one scenario") }
    for s in m.scenarios {
      let obj = s.objective ?? "mainThreadCpuMsPerStep"
      if !Self.objectives.contains(obj) { add("scenario \(s.name)", .fail, "objective \(obj) is not one the runner reads", fix: "one of " + Self.objectives.sorted().joined(separator: ", ")) }
      else if s.kind == "latency" && obj != "latencyMs" { add("scenario \(s.name)", .warn, "a latency scenario climbing on \(obj)") }
      else { add("scenario \(s.name)", .ok, "\(s.kind), climbs on \(obj), guarded by \(GuardNames.correctness(s).joined(separator: ", "))") }
      if let sf = s.secondFixture, !m.fixtureNames.contains(sf) { add("scenario \(s.name)", .fail, "second fixture \(sf) is not in the manifest's fixtures") }
    }
    for i in m.isolationGuards ?? [] where m.scenario(i) == nil { add("isolation", .fail, "isolation scenario \(i) is not a scenario") }
    if m.fixtures.isEmpty { add("fixtures", .warn, "none listed: experiments must pass --fixture") }
    if let d = m.defaultFixture, !m.fixtureNames.contains(d) { add("fixtures", .fail, "default fixture \(d) is not listed") }

    // knobs
    for k in m.knobs {
      if let d = k.default, !k.accepts(d) { add("knob \(k.name)", .fail, "its default \(d) is outside its own choices or range") }
    }
    if !m.knobs.isEmpty { add("knobs", .ok, m.knobs.map { "\($0.name)=\($0.default ?? "?")" }.joined(separator: ", ")) }

    // verbs
    if !m.has(verb: "run") { add("verbs", .fail, "no `run`: knob experiments, sweeps and the guards need it") }
    add("pairs", .ok, m.defaultVia == "ab" ? "measured through the adapter's own ab" : "measured through two runs per pair (no ab)")

    // snapshot-diff needs the champion's snapdiff
    if m.scenarios.contains(where: { $0.guards.contains(GuardNames.snapshotDiff) }) {
      let png = scratch.appendingPathComponent("doctor-1px.png")
      try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      try? Data(base64Encoded: Self.onePixelPNG)?.write(to: png)
      defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: scratch.appendingPathComponent("doctor-diff.png")) }
      if m.has(verb: "snapdiff"), let o = try? a.snapdiff(png.path, png.path, params: "", diffOut: scratch.appendingPathComponent("doctor-diff.png").path), o.status == 0,
         let g = o.json?["guard"], GuardResult(json: g)?.pass == true {
        add("snapdiff", .ok, "compares snapshots (a picture against itself passes)")
      } else {
        add("snapdiff", .fail, "a scenario guards snapshot-diff but `snapdiff A.png A.png --json` didn't pass", fix: "answer snapdiff (ADAPTER.md §5) or drop snapshot-diff from the scenario's guards")
      }
    }
  }
}

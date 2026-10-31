import Foundation
import PerfLoopKit

/// An app's bench executable, driven as a child process: the runner never links the app (SPEC §2.1). Headless verbs
/// (`list`, `describe`, `diff`) are safe anywhere; `ab` and `run` open the app's window.
public struct Adapter {
  public let exe: String
  /// Where the call runs (C10) and the directory its outputs land in; nil: here, as a plain child.
  public var runner: Runner?
  public var workDir: URL?
  public init(exe: String) { self.exe = exe }
  public init(exe: String, runner: Runner?, workDir: URL?) { self.exe = exe; self.runner = runner; self.workDir = workDir }

  public struct Output {
    public var status: Int32
    public var stdout: String
    public var json: JSONValue? { PLJSON.firstObject(in: stdout) }
  }

  /// Runs the child to completion. stdout is captured; stderr goes to ours (`ab: A rep 1/1` progress) unless
  /// `quiet`. `env` is added to this process's environment.
  public static func spawn(_ exe: String, _ args: [String], env: [String: String] = [:], cwd: String? = nil, quiet: Bool = false) throws -> Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    var e = ProcessInfo.processInfo.environment; for (k, v) in env { e[k] = v }; p.environment = e
    if let c = cwd { p.currentDirectoryURL = URL(fileURLWithPath: c) }
    let out = Pipe(); p.standardOutput = out
    p.standardError = quiet ? FileHandle.nullDevice : FileHandle.standardError
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { throw PLError.harness("couldn't start \(exe): \(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Output(status: p.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
  }

  func call(_ args: [String], env: [String: String] = [:], quiet: Bool = false) throws -> Output {
    guard let r = runner, let w = workDir else { return try Self.spawn(exe, args, env: env, quiet: quiet) }
    let o = try r.run(exe, args, env: env, workDir: w)
    if o.status != interruptedStatus { try r.fetch(w) }
    return o
  }

  /// `list --json`: scenarios, fixtures, and `tool.build` (the stamp).
  public func list() throws -> JSONValue {
    let o = try call(["list", "--json"], quiet: true)
    guard o.status == 0, let v = o.json else { throw PLError.harness("\(exe) list --json failed (exit \(o.status))") }
    return v
  }

  /// `describe --json` as printed (perfloop.manifest/1), or nil when the adapter has no `describe`.
  public func describeRaw() -> String? {
    guard let o = try? call(["describe", "--json"], quiet: true), o.status == 0, let v = o.json, v["schema"]?.string?.hasPrefix("perfloop.manifest/") == true else { return nil }
    return o.stdout
  }

  /// The adapter's manifest: `describe --json`, else derived from `list --json` (adapters older than Phase 2).
  public func manifest(list: JSONValue? = nil) -> Manifest? {
    if let raw = describeRaw(), let m = try? PLJSON.decode(Manifest.self, from: Data(raw.utf8)) { return m }
    guard let l = list ?? (try? self.list()) else { return nil }
    return Manifest.derived(fromList: l)
  }

  /// One interleaved pair through the adapter's own `ab`, one rep a side; `first` runs before `second`.
  public func ab(first: String, second: String, scenario: String, fixture: String, params: [String: String], out: String, env: [String: String] = [:]) throws -> Output {
    var args = ["ab", "--a", first, "--b", second, scenario, "--fixture", fixture, "--reps", "1", "--json", "--out", out]
    for (k, v) in params.sorted(by: { $0.key < $1.key }) { args += ["--set", "\(k)=\(v)"] }
    return try call(args, env: env)
  }

  /// One rep of a scenario in this binary (`run --reps 1 --json`), knobs in `PERFLOOP_KNOBS`.
  public func run(scenario: String, fixture: String, params: [String: String], knobs: [String: String], env: [String: String] = [:]) throws -> Output {
    var args = ["run", scenario, "--fixture", fixture, "--reps", "1", "--json", "--quiet-check", "0"]
    for (k, v) in params.sorted(by: { $0.key < $1.key }) { args += ["--set", "\(k)=\(v)"] }
    return try call(args, env: (knobs.isEmpty ? [:] : ["PERFLOOP_KNOBS": Self.knobString(knobs)]).merging(env) { $1 })
  }

  /// `snapdiff A.png B.png --json`: the snapshot-diff guard, headless, in this (the champion's) adapter. Exit 0 within
  /// tolerance, 3 over it; the guard record is the output's `guard`.
  public func snapdiff(_ a: String, _ b: String, params: String, diffOut: String) throws -> Output {
    var args = ["snapdiff", a, b, "--json", "--diff-out", diffOut]
    for kv in params.split(separator: ",") { args += ["--guard-param", String(kv)] }
    return try call(args, quiet: true)
  }

  /// `diff A B --json`: the differential call tree of two profiles (headless).
  public func diff(_ a: String, _ b: String) throws -> Output { try call(["diff", a, b, "--json"]) }

  /// `k=v,k=v`, sorted, as `PERFLOOP_KNOBS` takes it (C4).
  public static func knobString(_ k: [String: String]) -> String { k.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
  public static func knobs(_ s: String) -> [String: String] {
    var d: [String: String] = [:]
    for part in s.split(separator: ",") { let kv = part.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { d[kv[0]] = kv[1] } }
    return d
  }
}

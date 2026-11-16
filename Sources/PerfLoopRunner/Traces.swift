import Foundation
import PerfLoopKit

/// `.trace` bundles on disk. An xctrace recording holds the recorded process's environment (tokens included), so none
/// should outlive its export: `perfloop profile` deletes what the adapter left (ProfileRun), `store gc` deletes what
/// anything else left, and `doctor` fails while one is there. A trace is kept only on purpose (`--keep-trace`: a profile
/// beside it says `traceKept` and `keepTrace` for it) and skipped while it is being recorded (a `.recording` marker beside it
/// naming a live process: `perfloop profile` and PerfLoopHost's `profile` write one).
public struct TraceFile: Equatable {
  public var path: String
  public var bytes: Int64
  public var kept: Bool
  public var recording: Bool
}

public enum Traces {
  /// Written (with the pid) into a profile's folder while it records.
  public static let marker = ".recording"

  /// Every `.trace` under `root` (not looking inside one), as paths under `root`'s own spelling.
  public static func find(under root: URL) -> [TraceFile] {
    guard let en = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var out: [TraceFile] = []
    for case let rel as String in en where rel.hasSuffix(".trace") {
      en.skipDescendants()
      let u = root.appendingPathComponent(rel)
      out.append(TraceFile(path: u.path, bytes: size(u), kept: keptOnPurpose(u), recording: live(marker: u.deletingLastPathComponent())))
    }
    return out.sorted { $0.path < $1.path }
  }

  /// A profile document beside the trace says it was kept on purpose (`traceKept` and `keepTrace` true, this trace's
  /// name).
  static func keptOnPurpose(_ trace: URL) -> Bool {
    let dir = trace.deletingLastPathComponent()
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
      guard let v = try? PLJSON.read(JSONValue.self, path: dir.appendingPathComponent(name).path), v["traceKept"]?.bool == true, v["keepTrace"]?.bool == true,
            let t = v["trace"]?.string else { continue }
      if URL(fileURLWithPath: t).lastPathComponent == trace.lastPathComponent { return true }
    }
    return false
  }

  static func live(marker dir: URL) -> Bool {
    guard let s = try? String(contentsOf: dir.appendingPathComponent(marker), encoding: .utf8), let p = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return WindowLock.alive(p)
  }

  public static func size(_ u: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int64 ?? 0 }
    guard let en = fm.enumerator(atPath: u.path) else { return 0 }
    var n: Int64 = 0
    for case let rel as String in en { n += (try? fm.attributesOfItem(atPath: u.appendingPathComponent(rel).path))?[.size] as? Int64 ?? 0 }
    return n
  }

  /// Deletes a trace and checks it is gone: nil when it is, else why it is still there.
  public static func delete(_ path: String) -> String? {
    var why: String?
    do { try FileManager.default.removeItem(atPath: path) } catch { why = "\(error.localizedDescription)" }
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return why ?? "it is still there after the delete"
  }

  /// "23 MB", "1.2 GB".
  public static func mb(_ bytes: Int64) -> String {
    let m = Double(bytes) / 1e6
    return m >= 1000 ? "\(Stats.round(m / 1000, 1)) GB" : "\(Int(m.rounded())) MB"
  }
}

extension Store {
  public struct TraceGC {
    public var removed: [TraceFile] = []
    public var failed: [(TraceFile, String)] = []
    /// Kept on purpose (`--keep-trace`), left because `all` was false.
    public var kept: [TraceFile] = []
    public var recording: [TraceFile] = []
  }

  /// Deletes every trace in the store that isn't being recorded and wasn't kept on purpose; `all` deletes the kept ones
  /// too (`store gc --traces`).
  public func gcTraces(all: Bool) -> TraceGC {
    var r = TraceGC()
    for t in Traces.find(under: root) {
      if t.recording { r.recording.append(t); continue }
      if t.kept && !all { r.kept.append(t); continue }
      if let why = Traces.delete(t.path) { r.failed.append((t, why)) } else { r.removed.append(t) }
    }
    return r
  }
}

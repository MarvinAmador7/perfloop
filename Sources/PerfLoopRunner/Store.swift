import Foundation
import PerfLoopKit

/// What went wrong, with the exit code SCHEMAS.md assigns it.
public enum PLError: Error, CustomStringConvertible {
  case usage(String), harness(String), refused(String)
  public var code: Int32 { switch self { case .usage: 1; case .harness: 2; case .refused: 6 } }
  public var description: String { switch self { case .usage(let s), .harness(let s), .refused(let s): s } }
}

/// The content-addressed store (SPEC §4.3): `${PERFLOOP_HOME:-~/.perfloop}/<app>/` with `builds/<sha256>/` (the
/// binary, its resource bundles, `build.json`, `manifest.json`), `exp/<id>/`, `traces/` (paths only), `ledger.jsonl`,
/// `champion.json`. Never inside a repo: traces carry the recorded process's environment.
public struct Store {
  public let root: URL
  public init(root: URL) { self.root = root }

  /// `--store DIR` > `$PERFLOOP_HOME/<app>` where app is `--app` > `$PERFLOOP_APP` > the only app already in the
  /// home > the bench's manifest (`fallbackApp`).
  public static func locate(store: String?, app: String?, env: [String: String] = ProcessInfo.processInfo.environment, fallbackApp: () -> String? = { nil }) throws -> Store {
    if let s = store { return Store(root: URL(fileURLWithPath: tilde(s))) }
    let home = URL(fileURLWithPath: tilde(env["PERFLOOP_HOME"] ?? "~/.perfloop"))
    if let a = app ?? env["PERFLOOP_APP"] { return Store(root: home.appendingPathComponent(a)) }
    let apps = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { !$0.hasPrefix(".") }
    if apps.count == 1 { return Store(root: home.appendingPathComponent(apps[0])) }
    if let a = fallbackApp() { return Store(root: home.appendingPathComponent(a)) }
    throw PLError.usage("which app's store? pass --app NAME or set PERFLOOP_APP (stores in \(home.path): \(apps.isEmpty ? "none" : apps.joined(separator: ", ")))")
  }

  /// `~/x` → the home directory's x (no NSString bridging: the runner builds on Linux).
  static func tilde(_ p: String) -> String { p == "~" || p.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst() : p }

  public var ledger: Ledger { Ledger(path: root.appendingPathComponent("ledger.jsonl").path) }
  var builds: URL { root.appendingPathComponent("builds") }
  public func expDir(_ id: String) -> URL { root.appendingPathComponent("exp").appendingPathComponent(id) }
  public func rel(_ u: URL) -> String { u.path.hasPrefix(root.path + "/") ? String(u.path.dropFirst(root.path.count + 1)) : u.path }
  public func abs(_ rel: String) -> String { rel.hasPrefix("/") ? rel : root.appendingPathComponent(rel).path }

  // MARK: builds

  public struct Entry {
    public var build: Build
    public var dir: URL
    public var executable: String { dir.appendingPathComponent(build.executable ?? "bench").path }
    public var manifest: Manifest? { try? PLJSON.read(Manifest.self, path: dir.appendingPathComponent("manifest.json").path) }
  }

  /// The executable of a bench given as a file or as a directory holding one.
  public static func executable(at path: String, named: String? = nil) throws -> URL {
    let u = URL(fileURLWithPath: tilde(path)).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw PLError.usage("no such bench: \(u.path)") }
    if !isDir.boolValue { return u }
    if let n = named { return u.appendingPathComponent(n) }
    let exes = ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted().filter { name in
      var d: ObjCBool = false
      let p = u.appendingPathComponent(name).path
      return FileManager.default.fileExists(atPath: p, isDirectory: &d) && !d.boolValue && FileManager.default.isExecutableFile(atPath: p) && !name.hasSuffix(".dylib")
    }
    guard exes.count == 1 else { throw PLError.usage(exes.isEmpty ? "no executable in \(u.path)" : "several executables in \(u.path) (\(exes.joined(separator: ", "))): pass --exe NAME") }
    return u.appendingPathComponent(exes[0])
  }

  /// Copies a bench (its executable and the `*.bundle` resource directories beside it) under its hash. Idempotent:
  /// a build already in the store is returned as it is.
  func put(executable exe: URL, build: Build, manifest: Manifest?) throws -> Entry {
    guard let hash = build.hash else { throw PLError.harness("no hash for \(exe.path)") }
    let dir = builds.appendingPathComponent(hash.hasPrefix("sha256:") ? String(hash.dropFirst(7)) : hash)
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.appendingPathComponent("build.json").path), let e = try? entry(hash) { return e }
    let tmp = builds.appendingPathComponent(".incoming-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    try fm.copyItem(at: exe, to: tmp.appendingPathComponent(exe.lastPathComponent))
    let parent = exe.deletingLastPathComponent()
    for name in ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []) where name.hasSuffix(".bundle") {
      try fm.copyItem(at: parent.appendingPathComponent(name), to: tmp.appendingPathComponent(name))
    }
    var b = build; b.schema = "perfloop.build/1"; b.executable = exe.lastPathComponent; b.importedAt = b.importedAt ?? Clock.now()
    try PLJSON.write(b, path: tmp.appendingPathComponent("build.json").path)
    if let m = manifest { try PLJSON.write(m, path: tmp.appendingPathComponent("manifest.json").path) }
    try? fm.removeItem(at: dir)
    try fm.moveItem(at: tmp, to: dir)                      // a half-copied build never looks complete
    return Entry(build: b, dir: dir)
  }

  /// `store import DIR --commit SHA --note …`: a bench that predates the build stamp. The importer vouches for the
  /// commit; the build says `stamp: false` forever.
  public func importBench(_ path: String, exe name: String? = nil, commit: String, dirty: Bool, note: String?) throws -> Entry {
    let exe = try Self.executable(at: path, named: name)
    guard let hash = FileHash.sha256(file: exe.path) else { throw PLError.harness("can't read \(exe.path)") }
    var b = Build(hash: hash, commit: commit, dirty: dirty, stamp: false)
    b.note = note
    let m = Adapter(exe: exe.path).manifest()
    if let mb = m?.build, mb.stamp { b = mb; b.hash = hash; b.note = note }           // it had a stamp after all
    return try put(executable: exe, build: b, manifest: m)
  }

  /// `store add PATH`: a stamped bench. Its `list --json` says what it is (`tool.build`); an unstamped one is
  /// refused (use `store import` and say which commit it is).
  public func add(_ path: String, exe name: String? = nil) throws -> Entry {
    let exe = try Self.executable(at: path, named: name)
    guard let hash = FileHash.sha256(file: exe.path) else { throw PLError.harness("can't read \(exe.path)") }
    let a = Adapter(exe: exe.path)
    let list = try a.list()
    guard var b = Build(json: list["tool"]?["build"]), b.stamp else {
      throw PLError.refused("unstamped: \(exe.path) has no build stamp (tool.build in `list --json`); import it with `perfloop store import \(path) --commit SHA --note …`")
    }
    if let h = b.hash, h != hash { throw PLError.refused("the bench says it is \(Build.short(h)) but the file hashes to \(Build.short(hash))") }
    b.hash = hash
    return try put(executable: exe, build: b, manifest: a.manifest(list: list))
  }

  /// A build by hash or unique hash prefix (with or without `sha256:`).
  public func entry(_ key: String) throws -> Entry {
    let k = key.hasPrefix("sha256:") ? String(key.dropFirst(7)) : key
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: builds.path)) ?? []).filter { $0.hasPrefix(k) && !$0.hasPrefix(".") }
    guard names.count == 1 else { throw PLError.usage(names.isEmpty ? "no build \(key) in the store" : "\(key) is ambiguous: \(names.count) builds") }
    let dir = builds.appendingPathComponent(names[0])
    return Entry(build: try PLJSON.read(Build.self, path: dir.appendingPathComponent("build.json").path), dir: dir)
  }

  public func entries() -> [Entry] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: builds.path)) ?? []).filter { !$0.hasPrefix(".") }
    return names.compactMap { try? entry($0) }.sorted { ($0.build.importedAt ?? "") < ($1.build.importedAt ?? "") }
  }

  /// Keeps the newest `keep` builds, every champion the ledger has seen, and every build an open experiment uses.
  /// Returns the hashes removed.
  @discardableResult
  public func gc(keep: Int = 20) -> [String] {
    var pinned = Set(ledger.entries().filter { $0.state == ExpState.promoted.rawValue }.compactMap(\.build))
    if let c = champion(), let h = c.build.hash { pinned.insert(h) }
    for e in experiments() where !e.state.terminal { if let h = e.build?.hash { pinned.insert(h) } }
    let all = entries()
    var removed: [String] = []
    for e in all.dropLast(keep) where !pinned.contains(e.build.hash ?? "") {
      try? FileManager.default.removeItem(at: e.dir); removed.append(e.build.hash ?? e.dir.lastPathComponent)
    }
    return removed
  }

  // MARK: experiments and the champion

  public func champion() -> Champion? { try? PLJSON.read(Champion.self, path: root.appendingPathComponent("champion.json").path) }
  public func setChampion(_ c: Champion) throws { try PLJSON.write(c, path: root.appendingPathComponent("champion.json").path) }

  public func experiment(_ id: String) throws -> Experiment {
    let i = Self.id(id)
    let p = expDir(i).appendingPathComponent("experiment.json").path
    guard FileManager.default.fileExists(atPath: p) else { throw PLError.usage("no experiment \(i) in \(root.path)") }
    return try PLJSON.read(Experiment.self, path: p)
  }
  public func save(_ e: Experiment) throws { try PLJSON.write(e, path: expDir(e.id).appendingPathComponent("experiment.json").path) }
  public func experiments() -> [Experiment] {
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("exp").path)) ?? []).sorted()
    return ids.compactMap { try? experiment($0) }
  }
  public func nextID() -> String {
    let n = experiments().compactMap { Int($0.id) }.max().map { $0 + 1 } ?? 0
    return String(format: "%04d", n)
  }
  /// "exp/0007", "0007", "7" → "0007".
  public static func id(_ s: String) -> String {
    let t = s.hasPrefix("exp/") ? String(s.dropFirst(4)) : s
    return Int(t).map { String(format: "%04d", $0) } ?? t
  }
}

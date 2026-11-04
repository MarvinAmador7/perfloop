import Foundation
import PerfLoopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where `doctor`'s machine readings come from: this Mac by default, anything in tests.
public struct MachineProbe {
  public var os: () -> OperatingSystemVersion = { ProcessInfo.processInfo.operatingSystemVersion }
  public var model: () -> String? = { MachineModel.local() }
  public var arm64: () -> Bool = {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }
  /// `xcrun --find xctrace`: only profiles need it.
  public var xctrace: () -> String? = {
    guard let o = try? Adapter.spawn("/usr/bin/xcrun", ["--find", "xctrace"], quiet: true), o.status == 0 else { return nil }
    let p = o.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return p.isEmpty ? nil : p
  }
  /// `DevToolsSecurity -status`: whether developer tools may attach to processes without a password prompt.
  public var devTools: () -> Bool? = {
    guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/DevToolsSecurity"),
          let o = try? Adapter.spawn("/usr/sbin/DevToolsSecurity", ["-status"], quiet: true) else { return nil }
    return o.stdout.contains("enabled")
  }
  public var idle: IdleSource = HIDIdleSource()
  /// Bytes free for important use on the volume holding `path` (or its nearest existing parent).
  public var freeBytes: (String) -> Int64? = { path in
    var u = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
    #if os(macOS)
    if let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return v }
    #endif
    return (try? FileManager.default.attributesOfFileSystem(forPath: u.path))?[.systemFreeSize] as? Int64
  }
  /// The git checkout `path` is inside, if any.
  public var gitTop: (String) -> String? = { path in
    var u = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
    guard let o = try? Adapter.spawn("/usr/bin/env", ["git", "-C", u.path, "rev-parse", "--show-toplevel"], quiet: true), o.status == 0 else { return nil }
    let t = o.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
  /// Whether git ignores `path` (a project-local `.perfloop/` in .gitignore is allowed: SPEC §4.3).
  public var gitIgnored: (String) -> Bool = { path in
    var u = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
    let o = try? Adapter.spawn("/usr/bin/env", ["git", "-C", u.path, "check-ignore", "-q", path], quiet: true)
    return o?.status == 0
  }
  /// The 1-minute load average and the number of cores.
  public var load: () -> (Double, Int)? = {
    var l = [Double](repeating: 0, count: 3)
    guard getloadavg(&l, 3) > 0 else { return nil }
    return (l[0], ProcessInfo.processInfo.activeProcessorCount)
  }
  public init() {}
}

extension Doctor {
  /// This Mac, for local runs: what would make a rep untrusted or a run fail, and what only some verbs need.
  public mutating func checkMachine(store: URL?, env: [String: String] = ProcessInfo.processInfo.environment, probe p: MachineProbe = MachineProbe()) {
    let v = p.os()
    let os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    #if os(macOS)
    if v.majorVersion < 14 { add("macOS", .fail, "\(os): PerfLoopHost needs macOS 14 or later") }
    else { add("macOS", .ok, "\(os) on \(p.model() ?? "an unknown model")") }
    if !p.arm64() { add("sampler", .warn, "not Apple silicon: the in-process stack sampler is off (stretches have no stacks); everything else works") }
    #else
    add("platform", .warn, "not macOS (\(os)): only the headless verbs work here (store, explain, ledger, sweep plans); windowed runs need a Mac (--runner ssh://…)")
    #endif

    if let x = p.xctrace() { add("xctrace", .ok, x) }
    else { add("xctrace", .warn, "not found: only profiles (deskbench profile, perfloop diff) need it; the loop doesn't", fix: "install Xcode and `sudo xcode-select -s /Applications/Xcode.app`") }
    switch p.devTools() {
    case true?: add("developer tools", .ok, "DevToolsSecurity enabled (profilers attach without a prompt)")
    case false?: add("developer tools", .warn, "DevToolsSecurity disabled: xctrace may ask for a password to attach; the loop itself doesn't need it", fix: "sudo DevToolsSecurity -enable (only for profiles)")
    case nil: break
    }

    let r = p.idle.read()
    if r.locked == true {
      add("screen", .fail, "locked: a window behind the lock screen is never active, so every local rep would be untrusted",
          fix: "unlock it (or run on another Mac: --runner ssh://user@host, whose screen must be unlocked too)")
    } else if r.idle != nil || r.locked == false {
      add("screen", .ok, "unlocked")
    }
    if let i = r.idle {
      let front = r.frontmost.map { ", frontmost \($0)" } ?? ""
      if let f = r.frontmost, IdleGate.defaultBusyApps.contains(f) { add("idle", .warn, "\(f) is frontmost: someone is in a call, a presentation or a film", fix: "queue the runs: perfloop queue run --runner local --idle 120") }
      else if i < 120 { add("idle", .warn, "last input \(Int(i)) s ago\(front): someone is using this Mac; a run takes focus and their input makes noise",
                            fix: "run when the Mac is free, or let the queue wait for it: perfloop queue run --runner local --idle 120") }
      else { add("idle", .ok, "nobody has touched this Mac for \(Int(i)) s\(front)") }
    }
    if let (l, n) = p.load() {
      let s = "load \(Stats.round(l, 2)) on \(n) cores"
      if l > Double(n) * 0.5 { add("load", .warn, "\(s): the machine is busy; numbers will be noisy (and untrusted when the window can't keep up)", fix: "close what's running (builds, indexing, other benches) or use a spare Mac") }
      else { add("load", .ok, s) }
    }

    // The store.
    let home = env["PERFLOOP_HOME"] ?? "~/.perfloop"
    let root = store?.path ?? Store.tilde(home)
    if let free = p.freeBytes(root) {
      let gb = Double(free) / 1e9
      let s = "\(Stats.round(gb, 1)) GB free where the store is (\(root))"
      if gb < 5 { add("disk", .fail, s + ": builds and traces will fill it", fix: "free space, or perfloop store gc; point PERFLOOP_HOME at a bigger volume") }
      else if gb < 20 { add("disk", .warn, s + ": every build is a copy of the bench, every trace hundreds of MB", fix: "perfloop store gc --keep 10; delete traces once their numbers are recorded") }
      else { add("disk", .ok, s) }
    }
    if let top = p.gitTop(root), p.gitIgnored(root) {
      add("store", .warn, "\(root) is inside the git checkout \(top), ignored by git: allowed, but traces (which carry environments) sit next to the code",
          fix: "prefer PERFLOOP_HOME=~/.perfloop; never force-add anything from it")
    } else if let top = p.gitTop(root) {
      add("store", .fail, "\(root) is inside the git checkout \(top): results carry home paths and traces carry environments; neither belongs in a repo",
          fix: "export PERFLOOP_HOME=~/.perfloop (or any directory outside a checkout)")
    } else {
      add("store", .ok, store.map { "\($0.path)" } ?? "\(Store.tilde(home))/<app> (set PERFLOOP_APP, or pass --app)")
    }
  }
}

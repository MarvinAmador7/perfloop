import Foundation
import PerfLoopKit

/// `ssh://[user@]host[:port][/store-dir]`: a spare Mac (SPEC §4.2, §7.2: the Mac mini). The runner copies the
/// content-addressed build (the binary, its resource bundles, `build.json`) into a store directory there with rsync, runs
/// the adapter there, and brings its result and artifacts back. The remote Mac needs nothing but a login: no Swift
/// toolchain, no perfloop. The store directory there is `~/.perfloop/<app>` unless the URL names one; the runner touches
/// nothing outside it (and `~/.perfloop/.runner`, where its launcher app lives).
///
/// Windows over SSH: a process started by sshd belongs to a background login session, not the console user's GUI
/// session (Apple TN2083); whether it may still talk to the WindowServer depends on the macOS version (on the mini's
/// 26.6, as the user logged in at the console, a plain-ssh start did get a window, occluded behind the lock screen like
/// every other). With `launch = .gui` (the default) the runner doesn't depend on that: it starts the adapter through
/// LaunchServices, `open -W -n` on a tiny launcher app (a shell script as its executable) that runs the rep's script,
/// so the adapter runs in the logged-in user's GUI session as if started from that Mac's Terminal. It needs that user
/// logged in at the console (checked: the owner of /dev/console), the screen unlocked (checked before every rep:
/// `CGSSessionScreenIsLocked` in ioreg's IOConsoleUsers; the runner waits while it is locked, since a window behind the
/// lock screen is occluded and never active) and the display awake (`caffeinate -u` before a rep, `-di` during it).
/// A pair whose window still wasn't active and key is unusable and redone, as anywhere.
public final class SSHRunner: Runner {
  public enum Launch: String { case gui, direct }

  public let spec: RunnerSpec
  public let user: String?
  public let host: String
  public let port: Int?
  let rootOverride: String?
  let store: Store
  public var ssh = ProcessInfo.processInfo.environment["PERFLOOP_SSH"] ?? "/usr/bin/ssh"
  public var rsync = ProcessInfo.processInfo.environment["PERFLOOP_RSYNC"] ?? "/usr/bin/rsync"
  public var launch: Launch = .gui
  /// The runner's name in results when it isn't `ssh://host` (a VM: `vm:tart/NAME`).
  public var nameOverride: String?
  /// A key of its own (`-i`, IdentitiesOnly) and a known_hosts of its own: a VM's, never the user's.
  public var identityFile: String?
  public var knownHostsFile: String?
  /// Trust a host key seen for the first time (`StrictHostKeyChecking=accept-new`); a changed key is always refused.
  public var acceptNewHostKey = false
  /// Added to the adapter's environment there.
  public var remoteEnv: [String: String] = [:]
  /// Gate reps on the remote Mac's own idle time too (`--idle` on an ssh runner; off by default: it's a spare Mac).
  public var gate: IdleGate?
  /// Wake the display before a rep (`caffeinate -u`). Off for the fake in tests.
  public var wake = ProcessInfo.processInfo.environment["PERFLOOP_SSH_WAKE"] != "0"
  public var deadline: Date?
  public var poll = 2.0
  public var log: (String) -> Void = { _ in }
  public var onWait: (String) -> Void = { _ in }

  struct Info { var home = "", model: String?, os: String?, host: String?, user: String?, console: String?, arch: String? }
  var info: Info?
  public internal(set) var remoteRoot = ""
  var prepared: [String: String] = [:]
  let controlPath: String

  public init(spec: RunnerSpec, user: String?, host: String, port: Int?, root: String?, store: Store) {
    self.spec = spec; self.user = user; self.host = host; self.port = port; rootOverride = root; self.store = store
    // A unix socket path is at most 104 bytes: %C is 40 hex characters, and ssh adds a 17-character suffix while it
    // binds. macOS's per-user temporary directory is already ~49.
    let t = FileManager.default.temporaryDirectory.path
    controlPath = (t.count + 64 < 104 ? t : "/tmp") + "/plssh-%C"
  }

  public var name: String { nameOverride ?? spec.name }
  var target: String { user.map { "\($0)@\(host)" } ?? host }
  /// The store root as the loop writes its paths (what comes back is rewritten to this).
  var localRoot: String { store.root.path }
  /// Every spelling of the store root a path may arrive in: as given, standardized (Foundation drops /private from
  /// /private/tmp and /private/var), with symlinks resolved, with and without /private. Longest first.
  var localRoots: [String] {
    let base = [store.root.path, store.root.standardizedFileURL.path, store.root.resolvingSymlinksInPath().path]
    var all = Set(base)
    for b in base { if b.hasPrefix("/private/") { all.insert(String(b.dropFirst(8))) } else if ["/tmp/", "/var/", "/etc/"].contains(where: b.hasPrefix) { all.insert("/private" + b) } }
    return all.filter { $0.count > 1 }.sorted { $0.count > $1.count }
  }

  // MARK: ssh plumbing

  var sshOptions: [String] {
    var o = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
             "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=300"]
    if acceptNewHostKey { o += ["-o", "StrictHostKeyChecking=accept-new"] }
    if let k = identityFile { o += ["-i", k, "-o", "IdentitiesOnly=yes"] }
    if let k = knownHostsFile { o += ["-o", "UserKnownHostsFile=\(k)"] }
    if let p = port { o += ["-p", String(p)] }
    return o
  }

  static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  /// The remote command: always /bin/sh, whatever the login shell is.
  func command(_ script: String) -> String { "/bin/sh -c " + Self.q(script) }

  /// Runs a script there to completion. A failed connection (ssh's 255) becomes a clear error.
  @discardableResult
  func remote(_ script: String, stdin: String? = nil, check: Bool = true) throws -> (status: Int32, out: String, err: String) {
    let r = try Self.exec(ssh, sshOptions + [target, command(script)], stdin: stdin)
    if r.status == 255 { throw classify(r.err) }
    if check && r.status != 0 { throw PLError.harness("\(name): `\(script.prefix(80))…` exited \(r.status): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
    return r
  }

  static func exec(_ exe: String, _ args: [String], stdin: String? = nil) throws -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let out = Pipe(), err = Pipe(), inp = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
    do { try p.run() } catch { throw PLError.harness("couldn't start \(exe): \(error)") }
    var e = Data()
    let g = DispatchGroup(); g.enter()
    DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)); try? inp.fileHandleForWriting.close() }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); g.wait()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
  }

  /// ssh's own failures, as what to do about them. perfloop never types a password (BatchMode).
  func classify(_ err: String) -> PLError {
    let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
    let last = e.split(separator: "\n").last.map(String.init) ?? e
    if e.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || e.contains("Host key for") && e.contains("has changed") {
      return .refused("\(name): \(host)'s host key has changed since ~/.ssh/known_hosts recorded it (another machine, or a reinstall). Check it, then `ssh-keygen -R \(host)` and connect once by hand")
    }
    if e.contains("Host key verification failed") || e.contains("No ED25519 host key is known") || e.contains("host key is known") {
      return .refused("\(name): \(host) isn't in ~/.ssh/known_hosts. Connect once by hand (`ssh \(target) true`) and check the fingerprint, or pass --accept-new-host-key to trust a first-seen key")
    }
    if e.contains("Permission denied") || e.contains("Too many authentication failures") {
      let key = ["id_ed25519", "id_ecdsa", "id_rsa"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/\($0).pub").path }.first { FileManager.default.fileExists(atPath: $0) }
      return .refused("\(name): \(target) refused this Mac's key (\(last)). Authorize it once on \(host): add \(key ?? "this Mac's public key (ssh-keygen -t ed25519)") to ~/.ssh/authorized_keys there (`ssh-copy-id\(key.map { " -i \($0)" } ?? "") \(target)` asks for the password once). perfloop logs in with keys only")
    }
    if e.contains("Could not resolve hostname") || e.contains("nodename nor servname") { return .harness("\(name): no such host \(host) (\(last))") }
    if e.contains("Connection refused") { return .harness("\(name): \(host) refuses SSH: turn on Remote Login there (System Settings → General → Sharing)") }
    if e.contains("timed out") || e.contains("No route to host") || e.contains("Host is down") || e.contains("Network is unreachable") {
      return .harness("\(name): can't reach \(host) (\(last)): asleep, off, or another network")
    }
    return .harness("\(name): ssh failed: \(e.isEmpty ? "exit 255" : last)")
  }

  /// `rsync -a` through the same ssh connection.
  func rsyncCopy(_ from: String, _ to: String, extra: [String] = []) throws {
    let e = ([ssh] + sshOptions).joined(separator: " ")
    let r = try Self.exec(rsync, ["-a"] + extra + ["-e", e, from, to])
    if r.status != 0 {
      if r.err.contains("Permission denied") || r.err.contains("Host key") { throw classify(r.err) }
      throw PLError.harness("\(name): rsync \(from) → \(to) exited \(r.status): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }

  /// A local path under the store root, as the runner's store has it.
  public func map(_ s: String) -> String {
    guard !remoteRoot.isEmpty else { return s }
    var t = s
    for r in localRoots where r != remoteRoot {
      if t == r { return remoteRoot }
      t = t.replacingOccurrences(of: r + "/", with: remoteRoot + "/")
    }
    return t
  }
  /// The reverse, for what comes back.
  public func unmap(_ s: String) -> String {
    guard !remoteRoot.isEmpty, remoteRoot != localRoot else { return s }
    return s.replacingOccurrences(of: remoteRoot + "/", with: localRoot + "/").replacingOccurrences(of: "\"\(remoteRoot)\"", with: "\"\(localRoot)\"")
  }

  // MARK: Runner

  public func identity() throws -> RunnerIdentity {
    let i = try connect()
    return RunnerIdentity(runner: name, model: i.model, host: i.host, os: i.os)
  }

  /// Connects once: who and what the machine is, where its store is, whether a GUI session is there.
  @discardableResult
  func connect() throws -> Info {
    if let i = info { return i }
    let script = """
    echo perfloop-remote; echo "home=$HOME"; echo "model=$(sysctl -n hw.model 2>/dev/null)"; echo "os=$(sw_vers -productVersion 2>/dev/null || uname -sr)"
    echo "host=$(hostname -s 2>/dev/null || hostname)"; echo "user=$(id -un)"; echo "console=$(stat -f %Su /dev/console 2>/dev/null)"; echo "arch=$(uname -m)"
    """
    let r = try remote(script)
    guard r.out.contains("perfloop-remote") else { throw PLError.harness("\(name): unexpected answer from \(host): \(r.out.prefix(200))") }
    var d: [String: String] = [:]
    for l in r.out.split(separator: "\n") { let kv = l.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { d[kv[0]] = kv[1] } }
    func v(_ k: String) -> String? { d[k].flatMap { $0.isEmpty ? nil : $0 } }
    let i = Info(home: d["home"] ?? "", model: v("model"), os: v("os"), host: v("host"), user: v("user"), console: v("console"), arch: v("arch"))
    guard !i.home.isEmpty else { throw PLError.harness("\(name): no home directory on \(host)") }
    let root = rootOverride.map { $0.hasPrefix("/~/") ? i.home + $0.dropFirst(2) : $0 } ?? "\(i.home)/.perfloop/\(store.root.lastPathComponent)"
    guard root.hasPrefix("/"), root.allSatisfy({ $0.isLetter || $0.isNumber || "/-._+,".contains($0) }) else {
      throw PLError.usage("\(name): the store directory there must be a plain absolute path (letters, digits, / - . _ + ,): \(root)")
    }
    if launch == .gui, let c = i.console, c != "?", c != i.user {
      throw PLError.refused("\(name): \(c == "root" ? "nobody is logged in at \(host)'s console" : "\(c) is logged in at \(host)'s console, not \(i.user ?? "the ssh user")"): the bench's window opens in \(i.user ?? "the user")'s GUI session. Log in there (Automatic login keeps it so after a restart), or --launch direct for an adapter without windows")
    }
    if let a = i.arch, let la = Self.localArch(), a != la { log("\(name): \(host) is \(a), this Mac \(la): the build must be universal or \(a)") }
    remoteRoot = root
    info = i
    log("\(name): \(i.user ?? "?")@\(i.host ?? host), \(i.model ?? "unknown model"), macOS \(i.os ?? "?"); store \(root)")
    return i
  }

  static func localArch() -> String? { (try? Adapter.spawn("/usr/bin/uname", ["-m"], quiet: true))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
  static func sha(_ path: String) -> String { "(shasum -a 256 \(q(path)) 2>/dev/null || sha256sum \(q(path))) | cut -d' ' -f1" }

  public func prepare(_ build: Store.Entry) throws -> String {
    try connect()
    let key = build.dir.lastPathComponent
    if let p = prepared[key] { return p }
    let rdir = "\(remoteRoot)/builds/\(key)", exe = build.build.executable ?? "bench", rexe = "\(rdir)/\(exe)"
    let want = (build.build.hash ?? "").replacingOccurrences(of: "sha256:", with: "")
    let have = try remote("if [ -f \(Self.q(rdir))/build.json ] && [ -f \(Self.q(rexe)) ]; then \(Self.sha(rexe)); fi").out.trimmingCharacters(in: .whitespacesAndNewlines)
    if have != want || want.isEmpty {
      log("\(name): copying build \(Build.short(build.build.hash ?? key)) to \(host)")
      let incoming = "\(remoteRoot)/builds/.incoming-\(UUID().uuidString)"
      try remote("mkdir -p \(Self.q(incoming))")
      try rsyncCopy(build.dir.path + "/", "\(target):\(incoming)/")
      let got = try remote("rm -rf \(Self.q(rdir)) && mv \(Self.q(incoming)) \(Self.q(rdir)) && \(Self.sha(rexe))").out.trimmingCharacters(in: .whitespacesAndNewlines)
      guard got == want else { throw PLError.harness("\(name): the copy of \(exe) on \(host) hashes to \(got.prefix(12)), the store's to \(want.prefix(12))") }
    }
    if launch == .gui { try ensureLauncher() }
    prepared[key] = rexe
    return rexe
  }

  var launcherApp: String { "\(info?.home ?? "~")/.perfloop/.runner/PerfLoopLauncher.app" }

  /// The launcher: an app bundle whose executable is `exec /bin/sh "$1"`, so `open -W -n APP --args SCRIPT` runs the
  /// script in the console user's GUI session and returns when it ends. Background-only: no Dock icon, no menu.
  func ensureLauncher() throws {
    let app = launcherApp
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>launch</string>
    <key>CFBundleIdentifier</key><string>dev.perfloop.launcher</string>
    <key>CFBundleName</key><string>PerfLoopLauncher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1</string>
    <key>LSBackgroundOnly</key><true/>
    </dict></plist>
    """
    try remote("""
    a=\(Self.q(app)); if grep -q dev.perfloop.launcher "$a/Contents/Info.plist" 2>/dev/null && [ -x "$a/Contents/MacOS/launch" ]; then exit 0; fi
    mkdir -p "$a/Contents/MacOS" && cat > "$a/Contents/Info.plist" && printf '#!/bin/sh\\nexec /bin/sh "$1"\\n' > "$a/Contents/MacOS/launch" && chmod 755 "$a/Contents/MacOS/launch"
    """, stdin: plist)
  }

  public func run(_ exe: String, _ args: [String], env: [String: String], workDir: URL) throws -> Adapter.Output {
    try connect()
    // A window behind the lock screen is occluded and never active: the rep would be untrusted. Wait for the screen to
    // be unlocked (and, with --idle, for the Mac to be idle).
    if let gate { try waitForIdle(gate) } else if launch == .gui { try waitForUnlock() }
    if let d = deadline, Date() >= d { throw RunnerStop.deadline(d) }
    let rwork = map(workDir.path), ctl = rwork + "/.perfloop-run"
    guard rwork.hasPrefix(remoteRoot + "/") else { throw PLError.harness("\(name): \(workDir.path) isn't under the store \(localRoot)") }
    let rexe = map(exe), rargs = args.map(map)
    let renv = env.mapValues(map).merging(remoteEnv) { $1 }
    let exports = renv.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Self.q($0.value))" }.joined(separator: "\n")
    let cmdline = ([rexe] + rargs).map(Self.q).joined(separator: " ")
    let child: Child
    switch launch {
    case .direct:
      let script = "mkdir -p \(Self.q(ctl)) && cd \(Self.q(rwork)) && echo $$ > \(Self.q(ctl + "/pid")) || exit 2\n\(exports)\nexec \(cmdline)"
      child = try Child(ssh, sshOptions + [target, command(script)])
    case .gui:
      // The rep's script, run by the launcher in the GUI session; its stdout, stderr and status go to files the ssh
      // side reads (stderr live, through tail).
      let caffeinate = "if [ -x /usr/bin/caffeinate ]; then set -- /usr/bin/caffeinate -di; else set --; fi"
      let rep = """
      #!/bin/sh
      echo $$ > \(Self.q(ctl + "/pid"))
      cd \(Self.q(rwork)) || { echo 2 > \(Self.q(ctl + "/status")); exit 2; }
      \(exports)
      \(caffeinate)
      "$@" \(cmdline) > \(Self.q(ctl + "/out")) 2>> \(Self.q(ctl + "/err"))
      echo $? > \(Self.q(ctl + "/status.tmp")) && mv \(Self.q(ctl + "/status.tmp")) \(Self.q(ctl + "/status"))
      """
      let wakeCmd = wake ? "[ -x /usr/bin/caffeinate ] && /usr/bin/caffeinate -u -t 2 >/dev/null 2>&1 &\n" : ""
      let side = """
      c=\(Self.q(ctl)); mkdir -p "$c" && rm -f "$c/status" "$c/out" && : > "$c/err" && cat > "$c/rep.sh" || exit 2
      \(wakeCmd)tail -n +1 -f "$c/err" >&2 & t=$!
      o=$(open -W -n -g \(Self.q(launcherApp)) --args "$c/rep.sh" 2>&1); s=$?
      i=0; while [ ! -f "$c/status" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
      sleep 0.3; kill -PIPE $t 2>/dev/null
      if [ ! -f "$c/status" ]; then echo "perfloop-runner: the launcher didn't run the rep (open exited $s: $o): is \(info?.user ?? "the user") logged in at the console?" >&2; exit 2; fi
      cat "$c/out"; exit $(cat "$c/status")
      """
      let inp = Pipe()
      child = try Child(ssh, sshOptions + [target, command(side)], stdin: inp.fileHandleForReading)
      inp.fileHandleForWriting.write(Data(rep.utf8)); try? inp.fileHandleForWriting.close()
    }
    if let gate {
      var last = try remoteIdle()
      while child.running {
        Thread.sleep(forTimeInterval: poll)
        guard child.running else { break }
        let now = (try? remoteIdle()) ?? IdleReading(idle: nil)
        if let w = gate.interrupted(previous: last, now: now) {
          log("\(name): interrupted: \(w); the rep is killed and redone"); onWait("interrupted on \(host): \(w)")
          try? remoteKill(ctl)
          child.kill()
          _ = child.finish()
          return Adapter.Output(status: interruptedStatus, stdout: "")
        }
        if now.idle != nil { last = now }
      }
    }
    let o = child.finish()
    if o.status == 255 { throw PLError.harness("\(name): the connection to \(host) dropped during the rep (ssh exit 255); it is redone on resume") }
    return Adapter.Output(status: o.status, stdout: unmap(o.stdout))
  }

  /// Kills the rep's script and its descendants there.
  func remoteKill(_ ctl: String) throws {
    try remote("""
    p=$(cat \(Self.q(ctl + "/pid")) 2>/dev/null) || exit 0
    all=$p; f=$p
    while [ -n "$f" ]; do n=""; for x in $f; do n="$n $(pgrep -P $x 2>/dev/null)"; done; f=$(echo $n); all="$all $f"; done
    kill -TERM $all 2>/dev/null; sleep 2; kill -KILL $all 2>/dev/null; true
    """, check: false)
  }

  /// The remote Mac's HIDIdleTime and whether its console session's screen is locked, both through ioreg (no GUI
  /// session needed): `IOConsoleUsers` carries `CGSSessionScreenIsLocked`.
  func remoteIdle() throws -> IdleReading {
    let r = try remote("""
    ioreg -c IOHIDSystem -d 4 -r -k HIDIdleTime 2>/dev/null | awk '/HIDIdleTime/ { print "idle=" $NF / 1000000000; exit }'
    if ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q true; then echo locked=1; else echo locked=0; fi
    """, check: false)
    return IdleReading(text: r.out)
  }

  /// Seconds between readings while the runner waits there.
  public var waitPoll = 15.0

  func waitForUnlock() throws {
    var said = false
    while try remoteIdle().locked == true {
      if !said { let t = "waiting on \(host): its screen is locked: a window behind the lock screen is never active (unlock it, or turn off the screen lock there)"; log(t); onWait(t); said = true }
      if let d = deadline, Date() >= d { throw RunnerStop.deadline(d) }
      Thread.sleep(forTimeInterval: waitPoll)
    }
    if said { log("\(host): unlocked: starting the rep") }
  }

  func waitForIdle(_ gate: IdleGate) throws {
    var lastKind: String?
    while true {
      let r = try remoteIdle()
      guard let w = gate.wait(r) else { return }
      if w.kind != lastKind {
        let t = "waiting on \(host): " + (w == .locked ? "its screen is locked: a window behind the lock screen is never active (unlock it, or turn off the screen lock there)" : w.text(threshold: gate.threshold))
        log(t); onWait(t); lastKind = w.kind
      }
      if let d = deadline, Date() >= d { throw RunnerStop.deadline(d) }
      Thread.sleep(forTimeInterval: waitPoll)
    }
  }

  /// rsyncs the rep's directory back next to the local one, rewrites the runner's paths to the store's in what came
  /// (results, guard records), moves it in, and empties the directory there: the runner keeps builds, not results.
  public func fetch(_ workDir: URL) throws {
    try connect()
    let local = workDir
    let rwork = map(local.path)
    let fm = FileManager.default
    let tmp = local.deletingLastPathComponent().appendingPathComponent(".fetch-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try rsyncCopy("\(target):\(rwork)/", tmp.path + "/", extra: ["--exclude", ".perfloop-run"])
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    let files = (fm.enumerator(atPath: tmp.path)?.allObjects as? [String] ?? []).sorted()
    for rel in files {
      let src = tmp.appendingPathComponent(rel), dst = local.appendingPathComponent(rel)
      var isDir: ObjCBool = false
      fm.fileExists(atPath: src.path, isDirectory: &isDir)
      if isDir.boolValue { try fm.createDirectory(at: dst, withIntermediateDirectories: true); continue }
      if ["json", "txt", "jsonl"].contains(src.pathExtension), let t = try? String(contentsOf: src, encoding: .utf8) {
        try unmap(t).write(to: src, atomically: true, encoding: .utf8)
      }
      try? fm.removeItem(at: dst)
      try fm.moveItem(at: src, to: dst)
    }
    guard rwork.hasPrefix(remoteRoot + "/") else { throw PLError.harness("\(name): \(local.path) isn't under the store \(localRoot)") }
    if rwork.hasPrefix(remoteRoot + "/exp/") { try remote("rm -rf \(Self.q(rwork))", check: false) }
  }

  public func close() {
    guard info != nil else { return }
    _ = try? Self.exec(ssh, ["-o", "ControlPath=\(controlPath)", "-O", "exit", target])
  }

  /// `runner check`: the connection, the machine, the session, the store there and its size.
  public func check() throws -> [String] {
    let i = try connect()
    var o = ["\(name): \(i.user ?? "?")@\(i.host ?? host), \(i.model ?? "unknown model"), macOS \(i.os ?? "?"), \(i.arch ?? "?")"]
    o.append("console: \(i.console ?? "unknown")\(i.console == i.user ? " (a GUI session for the window)" : "")")
    let r = try remote("if [ -d \(Self.q(remoteRoot)) ]; then du -sk \(Self.q(remoteRoot)) | cut -f1; ls \(Self.q(remoteRoot + "/builds")) 2>/dev/null | grep -vc '^\\.'; else echo 0; echo 0; fi", check: false)
    let n = r.out.split(separator: "\n").map(String.init)
    o.append("store: \(remoteRoot) (\(n.first.flatMap(Int.init).map { "\($0 / 1024) MB" } ?? "?"), \(n.dropFirst().first ?? "0") build(s))")
    if launch == .gui { o.append("launch: through LaunchServices (open -W -n \(launcherApp))") } else { o.append("launch: direct over ssh (no GUI session: windows won't open)") }
    if let idle = try? remoteIdle() {
      if let s = idle.idle { o.append("idle: \(Int(s)) s since the last input there") }
      if idle.locked == true { o.append("screen: LOCKED: a window there is occluded and never active, so reps wait until it is unlocked (or the screen lock is turned off there)") }
      else if idle.locked == false { o.append("screen: unlocked") }
    }
    if let r = try? remote("echo cores=$(sysctl -n hw.logicalcpu 2>/dev/null); echo load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'); ps -Ao pcpu=,comm= -r 2>/dev/null | head -8", check: false),
       let line = Self.loadLine(r.out) { o.append(line) }
    return o
  }

  /// `load: …` from the remote's core count, load average and busiest processes: a spare Mac running other work (a VM
  /// helper, a browser, an agent) is noise in every rep, even with its window trusted. nil when nothing could be read.
  static func loadLine(_ text: String) -> String? {
    var cores: Int?, load: Double?, busy: [(String, Double)] = []
    for l in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
      if l.hasPrefix("cores=") { cores = Int(l.dropFirst(6)); continue }
      if l.hasPrefix("load=") { load = Double(l.dropFirst(5)); continue }
      let f = l.split(separator: " ", maxSplits: 1)
      guard f.count == 2, let pct = Double(f[0]), pct >= 20 else { continue }
      let name = String(f[1].split(separator: "/").last ?? f[1])
      if ["ps", "sshd", "sshd-session", "sh", "head"].contains(where: { name.hasPrefix($0) }) { continue }
      busy.append((name, pct))
    }
    guard let c = cores, let ld = load else { return nil }
    var s = "load: \(ld) on \(c) cores"
    if !busy.isEmpty {
      s += "; busy there: " + busy.prefix(4).map { "\($0.0) \(Int($0.1.rounded())) %" }.joined(separator: ", ")
      s += ": other work on that Mac is noise in every rep (quit it, or run the bench as a dedicated user with nothing else open)"
    }
    return s
  }

  /// `runner clean`: removes the store directory there (builds and any results left), and the launcher.
  public func clean() throws -> String {
    try connect()
    try remote("rm -rf \(Self.q(remoteRoot)) \(Self.q(launcherApp)); rmdir \(Self.q(info!.home + "/.perfloop/.runner")) 2>/dev/null; true", check: false)
    let r = try remote("du -sk \(Self.q(info!.home + "/.perfloop")) 2>/dev/null | cut -f1", check: false)
    return "\(name): removed \(remoteRoot); ~/.perfloop there is \(r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gone" : r.out.trimmingCharacters(in: .whitespacesAndNewlines) + " KB")"
  }
}

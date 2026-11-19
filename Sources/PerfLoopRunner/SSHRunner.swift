import Foundation
import PerfLoopKit

/// `ssh://[user@]host[:port][/store-dir]`: a spare Mac (SPEC §4.2, §7.2: the Mac mini). The runner copies the
/// content-addressed build (the binary, its resource bundles, `build.json`) into a store directory there with rsync, runs
/// the adapter there, and brings its result and artifacts back. The remote Mac needs nothing but a login: no Swift
/// toolchain, no perfloop. The store directory there is `~/.perfloop/<app>-<store id>` unless the URL names one: each
/// store (this Mac's `PERFLOOP_HOME/<app>`, by the random id in its `.runner-id`) has its own there, so two sessions'
/// run and experiment ids never meet in one folder. The runner touches nothing outside it but `~/.perfloop/.runner`,
/// shared by every store: the launcher app, the lock its shell steps take, and `in-use/`, one file per running rep (its
/// pid and store directory) that `runner clean` reads so it never removes a store or the launcher a rep is using.
///
/// The connection: one ssh master per perfloop process (ControlPath with its pid), never shared with another session's
/// perfloop, so one session ending (`ssh -O exit`) never cuts another's reps. With `launch = .gui` a rep runs in the GUI
/// session, not under ssh: when the connection drops anyway, the rep goes on there, and the runner reconnects, waits
/// for its status and collects it (`collect`) instead of losing it.
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
  /// Where the idle gate reads instead of the remote Mac (the VM runner: its host, this Mac, where someone at the
  /// keyboard and the VM contend). Its screen lock isn't the gate's then: the guest's window doesn't sit behind it.
  public var idle: IdleSource?
  /// The quiet gate before each rep (on by default from the CLI, as locally). It reads the remote Mac, where the reps
  /// run (`remoteLoad`), unless `load` names another machine (the VM runner: its host). nil: no gate.
  public var quiet: QuietGate?
  public var load: LoadSource?
  /// The machine the quiet gate (and an `idle` source) reads, as its messages name it (default: the host).
  var quietPlace: String?
  public var quietPoll = 0.5
  var quietTimedOut = false
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
    // One master per perfloop process: another session's `ssh -O exit` on a shared one cut this one's reps (exit 255).
    let t = FileManager.default.temporaryDirectory.path, name = "/plssh-\(ProcessInfo.processInfo.processIdentifier)-%C"
    controlPath = (t.count + name.count + 55 < 104 ? t : "/tmp") + name
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

  /// Asked of the remote Mac (`test -r`, one ssh call): perfloop copies builds there, never fixture files. A path under
  /// this Mac's store is the remote store's (as the reps' arguments are rewritten); a relative one would be read from
  /// the rep's folder in the store there, which never holds it.
  public func missingFile(_ path: String) throws -> String? {
    guard path.hasPrefix("/") else {
      return "\(path) is relative: on \(name) the adapter reads it from the rep's folder in the store there, which has no such file. Give an absolute path that exists on \(host)"
    }
    try connect()
    let p = map(path)
    if try remote("test -r \(Self.q(p))", check: false).status == 0 { return nil }
    return "no readable file at \(p) on \(host) (\(name)): every rep there would fail on it. perfloop copies builds to \(host), not fixture files: copy it there (e.g. rsync), or give a path that exists there"
  }

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
    let id = try storeID()
    let root = rootOverride.map { $0.hasPrefix("/~/") ? i.home + $0.dropFirst(2) : $0 } ?? "\(i.home)/.perfloop/\(store.root.lastPathComponent)-\(id)"
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

  /// This store's id on runners: 8 random hex characters kept in the store's `.runner-id`, made the first time. Not
  /// derived from the path or the host: two Macs' stores at the same path, or one Mac renamed, stay apart and stay put.
  func storeID() throws -> String {
    let f = store.root.appendingPathComponent(".runner-id")
    if let t = try? String(contentsOf: f, encoding: .utf8) {
      let id = t.trimmingCharacters(in: .whitespacesAndNewlines)
      if id.count == 8, id.allSatisfy(\.isHexDigit) { return id }
    }
    let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
    try (id + "\n").write(to: f, atomically: true, encoding: .utf8)
    return id
  }

  static func localArch() -> String? { (try? Adapter.spawn("/usr/bin/uname", ["-m"], quiet: true))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
  static func sha(_ path: String) -> String { "(shasum -a 256 \(q(path)) 2>/dev/null || sha256sum \(q(path))) | cut -d' ' -f1" }

  public func prepare(_ build: Store.Entry) throws -> String {
    try connect()
    let key = build.dir.lastPathComponent
    if let p = prepared[key] { return p }
    let rdir = "\(remoteRoot)/builds/\(key)", exe = build.build.executable ?? "bench", rexe = "\(rdir)/\(exe)"
    let want = (build.build.hash ?? "").replacingOccurrences(of: "sha256:", with: "")
    // `.perfloop-runner` marks the folder as a runner's store (`runner clean --all` removes only those).
    let mark = "\(remoteRoot)/.perfloop-runner"
    let have = try remote("mkdir -p \(Self.q(remoteRoot)) && { [ -f \(Self.q(mark)) ] || echo \(Self.q(storeIDLine)) > \(Self.q(mark)); } || exit 2\n"
                          + "if [ -f \(Self.q(rdir))/build.json ] && [ -f \(Self.q(rexe)) ]; then \(Self.sha(rexe)); fi").out.trimmingCharacters(in: .whitespacesAndNewlines)
    if have != want || want.isEmpty {
      log("\(name): copying build \(Build.short(build.build.hash ?? key)) to \(host)")
      let incoming = "\(remoteRoot)/builds/.incoming-\(UUID().uuidString)"
      try remote("mkdir -p \(Self.q(incoming))")
      try rsyncCopy(build.dir.path + "/", "\(target):\(incoming)/")
      let got = try remote("rm -rf \(Self.q(rdir)) && mv \(Self.q(incoming)) \(Self.q(rdir)) && \(Self.sha(rexe))").out.trimmingCharacters(in: .whitespacesAndNewlines)
      guard got == want else { throw PLError.harness("\(name): the copy of \(exe) on \(host) hashes to \(got.prefix(12)), the store's to \(want.prefix(12))") }
    }
    prepared[key] = rexe
    return rexe
  }

  /// What `.perfloop-runner` in the store there says: whose store it is.
  var storeIDLine: String { "perfloop runner store \((try? storeID()) ?? "?") of \(MachineModel.shortHost()):\(store.root.path)" }

  /// `~/.perfloop/.runner` there: shared by every store on that Mac.
  var runnerDir: String { "\(info?.home ?? "~")/.perfloop/.runner" }
  var launcherApp: String { "\(runnerDir)/PerfLoopLauncher.app" }

  /// Shell: `R`, the runner's shared folder, and `lock`/`unlock` around a change to it (the launcher, `in-use/`), so a
  /// rep starting and another session's `runner clean` never interleave. A `mkdir` lock: its holders take
  /// milliseconds, so one still held after 10 s of waiting is a dead holder's and is broken.
  var lockShell: String {
    """
    R=\(Self.q(runnerDir))
    lock() { i=0; while ! mkdir "$R/lock" 2>/dev/null; do mkdir -p "$R/in-use"; i=$((i+1)); if [ $i -ge 100 ]; then rmdir "$R/lock" 2>/dev/null; i=0; fi; sleep 0.1; done; mkdir -p "$R/in-use"; }
    unlock() { rmdir "$R/lock" 2>/dev/null; true; }
    """
  }

  /// Shell, inside `lock`: the launcher, made when it isn't there (another session's `runner clean` may have removed it
  /// since this one's last rep): an app bundle whose executable is `exec /bin/sh "$1"`, so `open -W -n APP --args
  /// SCRIPT` runs the script in the console user's GUI session and returns when it ends. Background-only: no Dock icon,
  /// no menu. Its architecture is said outright (arm64 first): LaunchServices can't tell a script's, and on a Mac
  /// without Rosetta (a fresh VM) it refused to start it as an Intel app (error -10669).
  var launcherShell: String {
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
    <key>LSArchitecturePriority</key><array><string>arm64</string><string>x86_64</string></array>
    </dict></plist>
    """
    return """
    a=\(Self.q(launcherApp)); if ! grep -q LSArchitecturePriority "$a/Contents/Info.plist" 2>/dev/null || [ ! -x "$a/Contents/MacOS/launch" ]; then
    mkdir -p "$a/Contents/MacOS" && printf '%s\\n' \(Self.q(plist)) > "$a/Contents/Info.plist" && printf '#!/bin/sh\\nexec /bin/sh "$1"\\n' > "$a/Contents/MacOS/launch" && chmod 755 "$a/Contents/MacOS/launch" || { unlock; exit 2; }
    fi
    """
  }

  public func run(_ exe: String, _ args: [String], env: [String: String], workDir: URL) throws -> Adapter.Output {
    try connect()
    // A window behind the lock screen is occluded and never active: the rep would be untrusted. Wait for the screen to
    // be unlocked (and, with --idle, for the Mac to be idle; a VM's guest for its own unlock, then for its host's idle).
    if let gate, idle == nil { try waitForIdle(gate) } else if launch == .gui { try waitForUnlock() }
    if let gate, idle != nil { try waitForIdle(gate) }
    if let d = deadline, Date() >= d { throw RunnerStop.deadline(d) }
    // The quiet gate reads the machine the reps run on (or the VM's host), never this one.
    var machine: MachineState?
    if let q = quiet {
      machine = try QuietWait.wait(q, on: quietPlace ?? host, timedOut: &quietTimedOut, poll: quietPoll, read: { load?.readLoad() ?? remoteLoad() }, log: log, onWait: onWait,
                                   check: { if let d = deadline, Date() >= d { throw RunnerStop.deadline(d) } })
    }
    let rwork = map(workDir.path), ctl = rwork + "/.perfloop-run"
    guard rwork.hasPrefix(remoteRoot + "/") else { throw PLError.harness("\(name): \(workDir.path) isn't under the store \(localRoot)") }
    let rexe = map(exe), rargs = args.map(map)
    let renv = env.mapValues(map).merging(remoteEnv) { $1 }
    let exports = renv.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Self.q($0.value))" }.joined(separator: "\n")
    let cmdline = ([rexe] + rargs).map(Self.q).joined(separator: " ")
    let child: Child
    // The rep's own status line carries it: a collect after a drop never takes an earlier rep's status for this one's.
    let token = String(UUID().uuidString.prefix(8))
    switch launch {
    case .direct:
      // The adapter keeps this shell's pid (exec): its in-use file says the rep runs while it does.
      let script = "mkdir -p \(Self.q(ctl)) && cd \(Self.q(rwork)) && echo $$ > \(Self.q(ctl + "/pid")) || exit 2\n\(lockShell)\nlock; echo \(Self.q(remoteRoot)) > \"$R/in-use/side.$$\"; unlock\n\(exports)\nexec \(cmdline)"
      child = try Child(ssh, sshOptions + [target, command(script)])
    case .gui:
      // The rep's script, run by the launcher in the GUI session; its stdout, stderr and status go to files the ssh
      // side reads (stderr live, through tail).
      let caffeinate = "if [ -x /usr/bin/caffeinate ]; then set -- /usr/bin/caffeinate -di; else set --; fi"
      // Its in-use file lives as long as it does, whatever becomes of the ssh side.
      let inUse = Self.q(runnerDir + "/in-use") + "/rep.$$"
      let rep = """
      #!/bin/sh
      echo $$ > \(Self.q(ctl + "/pid"))
      mkdir -p \(Self.q(runnerDir + "/in-use")) && echo \(Self.q(remoteRoot)) > \(inUse)
      cd \(Self.q(rwork)) || { echo 2 > \(Self.q(ctl + "/status")); rm -f \(inUse); exit 2; }
      \(exports)
      \(caffeinate)
      "$@" \(cmdline) > \(Self.q(ctl + "/out")) 2>> \(Self.q(ctl + "/err"))
      echo "$? \(token)" > \(Self.q(ctl + "/status.tmp")) && mv \(Self.q(ctl + "/status.tmp")) \(Self.q(ctl + "/status"))
      rm -f \(inUse)
      """
      let wakeCmd = wake ? "[ -x /usr/bin/caffeinate ] && /usr/bin/caffeinate -u -t 2 >/dev/null 2>&1 &\n" : ""
      // Under the lock: the launcher made if another session's `runner clean` removed it, and this side's in-use file
      // (until the rep's own is written) before anyone could remove either.
      let side = """
      c=\(Self.q(ctl)); mkdir -p "$c" && rm -f "$c/status" "$c/out" "$c/pid" && : > "$c/err" && cat > "$c/rep.sh" || exit 2
      \(lockShell)
      lock
      \(launcherShell)
      echo \(Self.q(remoteRoot)) > "$R/in-use/side.$$"; trap 'rm -f "$R/in-use/side.$$"' EXIT
      unlock
      \(wakeCmd)tail -n +1 -f "$c/err" >&2 & t=$!
      o=$(open -W -n -g \(Self.q(launcherApp)) --args "$c/rep.sh" 2>&1); s=$?
      i=0; while [ ! -f "$c/status" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
      sleep 0.3; kill -PIPE $t 2>/dev/null
      if [ ! -f "$c/status" ]; then echo "perfloop-runner: the launcher didn't run the rep (open exited $s: $o): is \(info?.user ?? "the user") logged in at the console?" >&2; exit 2; fi
      cat "$c/out"; exit $(cut -d' ' -f1 "$c/status")
      """
      let inp = Pipe()
      child = try Child(ssh, sshOptions + [target, command(side)], stdin: inp.fileHandleForReading)
      inp.fileHandleForWriting.write(Data(rep.utf8)); try? inp.fileHandleForWriting.close()
    }
    if let gate {
      var last = try gateIdle()
      while child.running {
        Thread.sleep(forTimeInterval: poll)
        guard child.running else { break }
        let now = (try? gateIdle()) ?? IdleReading(idle: nil)
        if let w = gate.interrupted(previous: last, now: now) {
          log("\(name): interrupted: \(w); the rep is killed and redone"); onWait("interrupted on \(idlePlace): \(w)")
          try? remoteKill(ctl)
          child.kill()
          _ = child.finish()
          return Adapter.Output(status: interruptedStatus, stdout: "", machine: machine)
        }
        if now.idle != nil { last = now }
      }
    }
    let o = child.finish()
    if o.status == 255 {
      // In the GUI session the rep doesn't depend on the connection: collect it once it ends there.
      if launch == .gui { return try collect(ctl, token: token, machine: machine) }
      throw PLError.harness("\(name): the connection to \(host) dropped during the rep (ssh exit 255); it is redone on resume")
    }
    return Adapter.Output(status: o.status, stdout: unmap(o.stdout), machine: machine)
  }

  /// Seconds between tries while collecting a rep after the connection dropped, how long the rep may still run there,
  /// and how long the runner keeps trying to reconnect.
  public var collectPoll = 5.0
  public var collectTimeout = 1800.0
  public var reconnectTimeout = 600.0
  var startGrace = 20.0

  /// The rep whose connection dropped (ssh exit 255) runs on in the GUI session there (the launcher is LaunchServices',
  /// not sshd's): reconnects, waits for its status file, and returns its output as the rep's, as if nothing had dropped.
  /// A rep that ended there without a status, one still running after `collectTimeout` (killed), or a Mac unreachable
  /// for `reconnectTimeout` is the harness error it always was: the rep is redone.
  func collect(_ ctl: String, token: String, machine: MachineState?) throws -> Adapter.Output {
    let t = "\(name): the connection to \(host) dropped during the rep (ssh exit 255); the rep goes on there: reconnecting to collect it"
    log(t); onWait(t)
    let start = Date()
    var unreachable: (since: Date, why: String)?
    let script = """
    c=\(Self.q(ctl)); p=$(cat "$c/pid" 2>/dev/null); alive=0; if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then alive=1; fi
    if grep -q \(Self.q(" " + token)) "$c/status" 2>/dev/null; then echo "perfloop-collect=done $(cut -d' ' -f1 "$c/status")"; cat "$c/out"; elif [ $alive = 1 ]; then echo perfloop-collect=running
    elif [ -z "$p" ]; then echo perfloop-collect=starting; else echo perfloop-collect=gone; fi
    """
    while true {
      do {
        let r = try remote(script, check: false)
        unreachable = nil
        let first = r.out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = first.first.map(String.init) ?? ""
        if head.hasPrefix("perfloop-collect=done ") {
          let status = Int32(head.dropFirst("perfloop-collect=done ".count).trimmingCharacters(in: .whitespaces)) ?? 2
          log("\(name): collected the rep (exit \(status)) after the connection dropped")
          return Adapter.Output(status: status, stdout: unmap(first.count > 1 ? String(first[1]) : ""), machine: machine)
        }
        // No pid yet: the launcher may still be starting the rep (the ssh side gives it 10 s too).
        let starting = head == "perfloop-collect=starting" && Date().timeIntervalSince(start) < startGrace
        if head != "perfloop-collect=running" && !starting {
          let why = head == "perfloop-collect=starting" ? "the rep never started there" : head == "perfloop-collect=gone" ? "the rep there ended without a status"
            : "no word of the rep there (\(head.isEmpty ? "no answer" : head))"
          throw PLError.harness("\(name): the connection to \(host) dropped during the rep (ssh exit 255), and \(why); it is redone on resume")
        }
        if Date().timeIntervalSince(start) > collectTimeout {
          try? remoteKill(ctl)
          throw PLError.harness("\(name): the connection to \(host) dropped during the rep, and the rep was still running there \(Int(collectTimeout)) s later: killed; it is redone on resume")
        }
      } catch let e as PLError where e.code == 2 && !"\(e)".contains("dropped during the rep") {
        // Still unreachable: keep trying for a while (a Wi-Fi blip, a sleeping router), then give up as before.
        let u = unreachable ?? (Date(), "\(e)")
        unreachable = u
        if Date().timeIntervalSince(u.since) > reconnectTimeout {
          throw PLError.harness("\(name): the connection to \(host) dropped during the rep (ssh exit 255) and couldn't be made again for \(Int(reconnectTimeout)) s (\(u.why)); it is redone on resume")
        }
      }
      Thread.sleep(forTimeInterval: collectPoll)
    }
  }

  /// The remote Mac's load, for the quiet gate: the share of its cores busy over a second (`iostat`: 100 − idle) and
  /// its processes (`ps`), less this session's own. Unknown when nothing could be read (the gate then doesn't wait).
  func remoteLoad() -> LoadReading {
    guard let r = try? remote("""
    echo "load=$(iostat -n 0 -c 2 -w 1 2>/dev/null | tail -n 1 | awk '$3 ~ /^[0-9.]+$/ { print 100 - $3 }')"
    ps -A -o pid=,pcpu=,comm= 2>/dev/null
    """, check: false) else { return LoadReading(busyPct: nil) }
    return Self.remoteLoad(r.out)
  }

  /// The parsing half of `remoteLoad`, for tests: `load=PCT`, then `ps` lines (HostLoad.parse).
  static func remoteLoad(_ text: String) -> LoadReading {
    var pct: Double?, rest: [Substring] = []
    for l in text.split(separator: "\n") { if l.hasPrefix("load=") { pct = Double(l.dropFirst(5)) } else { rest.append(l) } }
    let ps = HostLoad.parse(rest.joined(separator: "\n")).filter { p in !p.name.hasPrefix("sshd") && !["sh", "iostat", "awk", "tail"].contains(p.name) }
    return LoadReading(busyPct: pct, processes: ps)
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

  /// What the idle gate reads: the remote Mac, or `idle` (a VM's host) without its screen lock.
  func gateIdle() throws -> IdleReading {
    guard let idle else { return try remoteIdle() }
    var r = idle.read(); r.locked = nil
    return r
  }

  /// The machine the idle gate reads, as its messages name it.
  var idlePlace: String { idle == nil ? host : quietPlace ?? "this Mac" }

  func waitForIdle(_ gate: IdleGate) throws {
    var lastKind: String?
    while true {
      let r = try gateIdle()
      guard let w = gate.wait(r) else { if lastKind != nil { log("\(idlePlace): idle \(Int(r.idle ?? 0)) s ≥ \(Int(gate.threshold)) s: starting the rep") }; return }
      if w.kind != lastKind {
        let t = "waiting on \(idlePlace): " + (w == .locked ? "its screen is locked: a window behind the lock screen is never active (unlock it, or turn off the screen lock there)" : w.text(threshold: gate.threshold))
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
    if rwork.hasPrefix(remoteRoot + "/exp/") || rwork.hasPrefix(remoteRoot + "/runs/") { try remote("rm -rf \(Self.q(rwork))", check: false) }
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
    if let q = quiet {
      let l = load?.readLoad() ?? remoteLoad(), at = quietPlace ?? host
      if l.unknown { o.append("quiet gate: the load on \(at) can't be read (no gate)") }
      else { o.append("quiet gate, on \(at): " + (q.busy(l).map { "not quiet: \($0); a rep would wait up to \(Int(q.timeout)) s" }
                                                   ?? "quiet: \(l.busyPct.map { "\(Int($0.rounded())) %" } ?? "?") of the cores busy (≤ \(Int(q.maxLoadPct)) %), no build running")) }
    }
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

  /// `runner clean`: removes this store's directory there (builds and any results left), never one a rep is running in
  /// (another session on this store), and the launcher once no store of a runner's is left there and no rep runs.
  /// `all`: every runner store there too (`.perfloop-runner` in it, or an older perfloop's `<app>` folder with builds
  /// and no ledger), still never one a rep is running in, nor one written to in the last 10 minutes (an older
  /// perfloop's reps leave no in-use file); a folder with a `ledger.jsonl` is a store of perfloop run on that Mac itself
  /// and is never touched. All under the runner's lock, so no rep starts halfway through.
  public func clean(all: Bool = false) throws -> String {
    let i = try connect()
    let base = i.home + "/.perfloop"
    let r = try remote("""
    \(lockShell)
    P=\(Self.q(base)); me=\(Self.q(remoteRoot)); all=\(all ? 1 : 0); live=""; n=0
    lock
    for m in "$R"/in-use/*; do
      [ -f "$m" ] || continue; p=${m##*.}
      if kill -0 "$p" 2>/dev/null; then live="$live$(cat "$m")
    "; else rm -f "$m"; fi
    done
    busy() { printf '%s' "$live" | grep -qxF "$1"; }
    gone() { if busy "$1"; then echo "busy=$1"; else rm -rf "$1" && echo "removed=$1"; fi; }
    recent() { [ -n "$(find "$1" -mmin -10 2>/dev/null | head -n 1)" ]; }
    kind() { if [ -f "$1/.perfloop-runner" ]; then echo runner; elif [ -f "$1/ledger.jsonl" ] || [ ! -d "$1/builds" ]; then echo own; else echo older; fi; }
    if [ -d "$me" ]; then gone "$me"; else echo "absent=$me"; fi
    for d in "$P"/*; do
      [ -d "$d" ] && [ "$d" != "$me" ] || continue
      k=$(kind "$d"); [ $k = own ] && continue
      u=0; if busy "$d"; then u=1; elif recent "$d"; then u=2; fi
      [ $all = 1 ] && [ $u = 0 ] && rm -rf "$d"
      if [ -d "$d" ]; then n=$((n+1)); echo "left=$k $u $(du -sk "$d" 2>/dev/null | cut -f1) $d"; fi
    done
    if [ -z "$live" ] && [ $n = 0 ]; then rm -rf "$R"; rmdir "$P" 2>/dev/null; echo launcher=removed; else echo launcher=kept; unlock; fi
    echo "size=$(du -sk "$P" 2>/dev/null | cut -f1)"
    """, check: false)
    return Self.cleanText(r.out, name: name, all: all)
  }

  /// `runner clean`'s report from what its script printed (`removed=`, `busy=`, `absent=`, `left=KIND INUSE KB DIR`,
  /// `launcher=`, `size=`).
  static func cleanText(_ out: String, name: String, all: Bool) -> String {
    var removed: [String] = [], busy: [String] = [], absent: String?, left: [(kind: String, use: String, kb: Int, dir: String)] = [], launcher = "kept", size = ""
    for l in out.split(separator: "\n").map(String.init) {
      let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
      guard kv.count == 2 else { continue }
      switch kv[0] {
      case "removed": removed.append(kv[1])
      case "busy": busy.append(kv[1])
      case "absent": absent = kv[1]
      case "launcher": launcher = kv[1]
      case "size": size = kv[1].trimmingCharacters(in: .whitespaces)
      case "left":
        let f = kv[1].split(separator: " ", maxSplits: 3).map(String.init)
        if f.count == 4 { left.append((f[0], f[1], Int(f[2]) ?? 0, f[3])) }
      default: break
      }
    }
    var parts: [String] = []
    if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
    if let a = absent, removed.isEmpty, busy.isEmpty { parts.append("nothing of this store's there (no \(a))") }
    for b in busy { parts.append("kept \(b): a rep is running in it (another perfloop session on this store); clean again once it ends") }
    if !left.isEmpty {
      let list = left.map { l -> String in
        let notes = [l.use == "1" ? "a rep running in it" : l.use == "2" ? "used in the last 10 minutes" : nil, l.kind == "older" ? "an older perfloop's" : nil].compactMap { $0 }
        return "\(URL(fileURLWithPath: l.dir).lastPathComponent) (\(([String(l.kb / 1024) + " MB"] + notes).joined(separator: ", ")))"
      }.joined(separator: ", ")
      parts.append(all ? "left \(left.count) store(s) in use (a rep running in it, or used in the last 10 minutes): \(list); clean again once they are done"
                       : "left \(left.count) other store(s) there: \(list) (other sessions' or other stores'; `perfloop runner clean \(name) --all` removes them too, except one in use)")
    }
    parts.append(launcher == "removed" ? "removed the launcher (no store or rep left to use it)" : "kept the launcher (\(left.isEmpty ? "a rep is running there" : "other stores there use it"))")
    parts.append("~/.perfloop there is \(size.isEmpty ? "gone" : size + " KB")")
    return "\(name): " + parts.joined(separator: "; ")
  }
}

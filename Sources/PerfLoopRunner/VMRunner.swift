import Foundation
import PerfLoopKit

/// `vm:tart/NAME`: a macOS VM on this Mac (SPEC §4.2), run with Tart (Apple's Virtualization framework). The runner
/// boots the VM headless (`tart run NAME --no-graphics`: the guest still has a display, and with automatic login a GUI
/// session, so the bench's window opens and draws), finds its address (`tart ip`), and is then the ssh runner against
/// it, under its own name, so its results are their own machine in the ledger and never mix with this Mac's.
///
/// It keeps its own key and known_hosts in `<store>/../.vm/NAME/` and never touches `~/.ssh`. The first time, it
/// installs that key in the guest with the image's password (`PERFLOOP_VM_PASSWORD`, `admin` in Cirrus Labs' images)
/// through SSH_ASKPASS; afterwards it logs in with the key only. A VM this runner booted is stopped when it closes.
///
/// What a VM's numbers are good for: main-thread CPU per step on the guest's virtual CPUs. PMU counters aren't there
/// (instructions may read zero), and display-link cadence and hitches in a guest aren't the panel's, so a VM screens and
/// never decides a full (`exp full` refuses it).
public final class VMRunner: Runner {
  public let tool: String
  public let vm: String
  let store: Store
  public var tart: String
  public var user: String
  public var password: String
  /// Where the VM's key, known_hosts and boot log live.
  public let stateDir: URL
  public var bootTimeout: Double = 180
  public var log: (String) -> Void = { _ in } { didSet { inner?.log = log } }
  public var onWait: (String) -> Void = { _ in } { didSet { inner?.onWait = onWait } }
  public var deadline: Date? { didSet { inner?.deadline = deadline } }
  /// Testing hooks for the inner ssh runner.
  public var ssh: String?
  public var rsync: String?
  public var wake = true
  var inner: SSHRunner?
  var booted: Child?

  public init(tool: String, name: String, store: Store) throws {
    guard tool == "tart" else { throw PLError.usage("vm:\(tool)/\(name): only Tart VMs (vm:tart/NAME)") }
    self.tool = tool; vm = name; self.store = store
    let env = ProcessInfo.processInfo.environment
    tart = env["PERFLOOP_TART"] ?? ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tart"
    user = env["PERFLOOP_VM_USER"] ?? "admin"
    password = env["PERFLOOP_VM_PASSWORD"] ?? "admin"
    stateDir = store.root.deletingLastPathComponent().appendingPathComponent(".vm").appendingPathComponent(name)
  }

  public var name: String { "vm:\(tool)/\(vm)" }

  func tartCall(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
    let exe = tart.contains("/") ? tart : "/usr/bin/env"
    return try SSHRunner.exec(exe, (tart.contains("/") ? [] : [tart]) + args)
  }

  /// The VM is running (booting it if needed), its address known, its key installed: the inner ssh runner.
  @discardableResult
  public func connect() throws -> SSHRunner {
    if let r = inner { return r }
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let list = try tartCall(["list", "--format", "json"])
    guard list.status == 0 else {
      throw PLError.usage("\(name): `\(tart) list` failed (\(list.err.trimmingCharacters(in: .whitespacesAndNewlines))): is Tart installed? (brew install cirruslabs/cli/tart, or PERFLOOP_TART=PATH)")
    }
    let vms = (try? PLJSON.decode(JSONValue.self, from: Data(list.out.utf8)))?.array ?? []
    guard let me = vms.first(where: { $0["Name"]?.string == vm }) else {
      throw PLError.usage("\(name): no VM named \(vm) (tart list: \(vms.compactMap { $0["Name"]?.string }.joined(separator: ", "))). Make one: tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:latest \(vm) (~24 GB)")
    }
    if me["State"]?.string != "running" {
      log("\(name): booting (tart run \(vm) --no-graphics)")
      let out = try FileHandle(forWritingTo: { let u = stateDir.appendingPathComponent("tart-run.log"); FileManager.default.createFile(atPath: u.path, contents: nil); return u }())
      booted = try Child(tart.contains("/") ? tart : "/usr/bin/env", (tart.contains("/") ? [] : [tart]) + ["run", vm, "--no-graphics"], stderr: out)
    }
    let ipr = try tartCall(["ip", vm, "--wait", String(Int(bootTimeout))])
    let ip = ipr.out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard ipr.status == 0, !ip.isEmpty, RunnerSpec("ssh://\(user)@\(ip)") != nil else { throw PLError.harness("\(name): no address for \(vm) within \(Int(bootTimeout)) s (\(ipr.err.trimmingCharacters(in: .whitespacesAndNewlines)))") }
    let key = stateDir.appendingPathComponent("id_ed25519").path, known = stateDir.appendingPathComponent("known_hosts").path
    if !FileManager.default.fileExists(atPath: key) {
      let g = try SSHRunner.exec("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "perfloop-vm-\(vm)", "-f", key])
      guard g.status == 0 else { throw PLError.harness("\(name): ssh-keygen failed: \(g.err)") }
    }
    let spec = RunnerSpec("ssh://\(user)@\(ip)")!
    let r = SSHRunner(spec: spec, user: user, host: ip, port: nil, root: nil, store: store)
    r.nameOverride = name; r.identityFile = key; r.knownHostsFile = known; r.acceptNewHostKey = true
    r.log = log; r.onWait = onWait; r.deadline = deadline; r.wake = wake
    if let s = ssh { r.ssh = s }
    if let s = rsync { r.rsync = s }
    // sshd comes up a little after the address; the key goes in once, with the image's password.
    let until = Date().addingTimeInterval(bootTimeout)
    while true {
      let t = try SSHRunner.exec(r.ssh, r.sshOptions + [r.target, "true"])
      if t.status == 0 { break }
      if t.err.contains("Permission denied") { try installKey(r, pub: key + ".pub"); continue }
      if Date() >= until { throw PLError.harness("\(name): ssh to \(ip) didn't come up in \(Int(bootTimeout)) s: \(t.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
      Thread.sleep(forTimeInterval: 2)
    }
    inner = r
    return r
  }

  /// Appends our key to the guest's authorized_keys, logging in once with the password (SSH_ASKPASS, never a prompt).
  func installKey(_ r: SSHRunner, pub: String) throws {
    log("\(name): installing this runner's key in \(vm) (once, with the image's password)")
    let askpass = stateDir.appendingPathComponent("askpass.sh").path
    try "#!/bin/sh\nprintf '%s\\n' \"$PERFLOOP_VM_PASSWORD_ASK\"\n".write(toFile: askpass, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass)
    let k = try String(contentsOfFile: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: r.ssh)
    p.arguments = ["-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
                   "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(r.knownHostsFile ?? "/dev/null")", "-o", "ConnectTimeout=10", r.target,
                   "/bin/sh -c " + SSHRunner.q("mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' \(SSHRunner.q(k)) >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")]
    var e = ProcessInfo.processInfo.environment
    e["SSH_ASKPASS"] = askpass; e["SSH_ASKPASS_REQUIRE"] = "force"; e["DISPLAY"] = e["DISPLAY"] ?? ":0"; e["PERFLOOP_VM_PASSWORD_ASK"] = password
    p.environment = e
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; let err = Pipe(); p.standardError = err
    try p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(atPath: askpass)
    guard p.terminationStatus == 0 else {
      throw PLError.refused("\(name): couldn't install the key in \(vm) with the image's password (PERFLOOP_VM_PASSWORD; \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
  }

  // MARK: Runner

  public func identity() throws -> RunnerIdentity { try connect().identity() }
  @discardableResult public func prepare(_ build: Store.Entry) throws -> String { try connect().prepare(build) }
  public func run(_ exe: String, _ args: [String], env: [String: String], workDir: URL) throws -> Adapter.Output { try connect().run(exe, args, env: env, workDir: workDir) }
  public func fetch(_ workDir: URL) throws { try connect().fetch(workDir) }
  public func check() throws -> [String] {
    var o = try connect().check()
    o.append("vm: \(vm) via \(tart)\(booted != nil ? " (booted by this check; stopped when it ends)" : " (was already running)"); its numbers screen and never decide a full")
    return o
  }
  public func clean() throws -> String { try connect().clean() }

  /// Ends the connection; stops the VM if this runner booted it.
  public func close() {
    inner?.close()
    guard let b = booted else { return }
    _ = try? tartCall(["stop", vm])
    if b.running { b.kill(grace: 10) }
    _ = b.finish()
    booted = nil
  }
}

import Foundation
import XCTest
@testable import PerfLoopKit

/// The window lock (F9): its owner file says who holds it, a waiter says so, a dead holder's lock is broken, a hold
/// never waits for itself, and a release never removes someone else's lock.
final class WindowLockTests: XCTestCase {
  var tmp: URL!
  var path: String { tmp.appendingPathComponent("window.lock").path }

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    unsetenv(WindowLock.heldVariable)
  }
  override func tearDownWithError() throws {
    WindowLock.releaseAll(); unsetenv(WindowLock.heldVariable)
    try? FileManager.default.removeItem(at: tmp)
  }

  /// A lock made by hand, as another process holding it would leave it.
  func hold(_ h: WindowLock.Holder) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try PLJSON.encode(h).write(toFile: path + "/owner", atomically: true, encoding: .utf8)
  }

  /// A pid that was alive a moment ago and isn't now.
  func deadPid() throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "exit 0"]
    try p.run(); p.waitUntilExit()
    return p.processIdentifier
  }

  func testTheDefaultPathIsSharedAndCanMoveOrBeOff() {
    XCTAssertEqual(WindowLock.defaultPath(env: [:]), "/tmp/perfloop-window-\(getuid()).lock", "not $TMPDIR: sandboxes give each agent its own")
    XCTAssertEqual(WindowLock.defaultPath(env: ["PERFLOOP_LOCK": "/x/w.lock"]), "/x/w.lock")
    XCTAssertNil(WindowLock.defaultPath(env: ["PERFLOOP_LOCK": "off"]))
  }

  func testTheOwnerFileSaysWhoAndReleaseRemovesIt() throws {
    let l = try WindowLock.acquire(path, command: "perfloop exp screen 0003", label: "palette")
    XCTAssertTrue(l.owned)
    let h = try XCTUnwrap(WindowLock.holder(at: path))
    XCTAssertEqual(h.pid, getpid()); XCTAssertEqual(h.command, "perfloop exp screen 0003"); XCTAssertEqual(h.label, "palette")
    XCTAssertNotNil(h.since.flatMap(Clock.date))
    XCTAssertEqual(ProcessInfo.processInfo.environment[WindowLock.heldVariable], path, "children know they are inside the hold")
    XCTAssertEqual(WindowLock.childEnv, [WindowLock.heldVariable: path])
    XCTAssertTrue(h.line().hasPrefix("pid \(getpid()) (perfloop exp screen 0003) \"palette\", since "), h.line())
    l.release()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    XCTAssertNil(ProcessInfo.processInfo.environment[WindowLock.heldVariable])
    XCTAssertEqual(WindowLock.state(at: path), .free)
  }

  func testAWaiterSaysWhoHoldsItAndGoesOnOnceItIsFree() throws {
    let other = WindowLock.Holder(pid: getppid(), command: "deskbench ab", label: "sidebar", since: Clock.now())
    try hold(other)
    XCTAssertEqual(WindowLock.state(at: path), .held(other))
    var said: [String] = []
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? FileManager.default.removeItem(atPath: self.path) }
    let l = try WindowLock.acquire(path, poll: 0.05, log: { said.append($0) })
    XCTAssertTrue(l.owned)
    XCTAssertEqual(said.filter { $0.hasPrefix("waiting:") }.count, 1, "said once, not once a poll: \(said)")
    XCTAssertTrue(said[0].contains("is held by pid \(getppid()) (deskbench ab) \"sidebar\", since"), said[0])
    l.release()
  }

  func testADeadHoldersLockIsBroken() throws {
    try hold(WindowLock.Holder(pid: try deadPid(), command: "perfloop exp screen 0001", since: Clock.now()))
    guard case .stale = WindowLock.state(at: path) else { return XCTFail("\(WindowLock.state(at: path))") }
    var said: [String] = []
    let l = try WindowLock.acquire(path, poll: 0.05, log: { said.append($0) })
    XCTAssertEqual(WindowLock.holder(at: path)?.pid, getpid())
    XCTAssertTrue(said.contains { $0.contains("which is gone: taking it over") }, "\(said)")
    l.release()
    // An older perfloop's owner file (`perfloop pid N`) is understood too.
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try "agent-a perfloop pid \(try deadPid())".write(toFile: path + "/owner", atomically: true, encoding: .utf8)
    guard case .stale(let h) = WindowLock.state(at: path) else { return XCTFail("\(WindowLock.state(at: path))") }
    XCTAssertTrue(h.line().hasPrefix("agent-a perfloop pid"), h.line())
  }

  #if os(macOS)
  func testAPidReusedSinceTheLockWasTakenIsStale() throws {
    // Our parent is alive, but it started long after 2001: that pid can't be the one that took the lock then.
    try hold(WindowLock.Holder(pid: getppid(), command: "perfloop exp full 0002", since: "2001-01-01T00:00:00Z"))
    guard case .stale = WindowLock.state(at: path) else { return XCTFail("\(WindowLock.state(at: path))") }
  }
  #endif

  func testAHandMadeLockIsNeverBrokenAndTheWaiterSaysSo() throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    XCTAssertEqual(WindowLock.state(at: path), .held(nil))
    var said: [String] = []
    struct Enough: Error {}
    XCTAssertThrowsError(try WindowLock.acquire(path, poll: 0.01, log: { said.append($0) }, check: { throw Enough() }))
    XCTAssertTrue(said.first?.contains("no owner file") == true, "\(said)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    // With a text owner file and no pid (a script's lock): held, its text shown.
    try "another agent\n".write(toFile: path + "/owner", atomically: true, encoding: .utf8)
    XCTAssertEqual(WindowLock.state(at: path), .held(WindowLock.Holder(raw: "another agent")))
  }

  func testInsideAHoldNothingWaits() throws {
    try hold(WindowLock.Holder(pid: getppid(), command: "perfloop lock -- deskbench ab", since: Clock.now()))
    let inner = try WindowLock.acquire(path, env: [WindowLock.heldVariable: path])
    XCTAssertFalse(inner.owned)
    inner.release()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the parent's lock stays")
    // A stale PERFLOOP_LOCK_HELD (its holder gone) is no hold.
    try FileManager.default.removeItem(atPath: path)
    try hold(WindowLock.Holder(pid: try deadPid(), command: "gone", since: Clock.now()))
    XCTAssertNil(WindowLock.inherited(env: [WindowLock.heldVariable: path]))
    // A process holding the lock asks again (a runner inside its own hold): no wait.
    try FileManager.default.removeItem(atPath: path)
    let outer = try WindowLock.acquire(path)
    XCTAssertFalse(try WindowLock.acquire(tmp.appendingPathComponent("other.lock").path, env: [:]).owned)
    outer.release()
  }

  func testAReleaseNeverRemovesSomeoneElsesLock() throws {
    let l = try WindowLock.acquire(path)
    // Someone broke it (wrongly) and took it: it is theirs now.
    try PLJSON.encode(WindowLock.Holder(pid: getppid(), command: "other", since: Clock.now())).write(toFile: path + "/owner", atomically: true, encoding: .utf8)
    l.release()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  func testACreateFailureSaysWhatToDo() {
    XCTAssertThrowsError(try WindowLock.acquire("/nonexistent-dir-\(UUID().uuidString)/window.lock")) {
      XCTAssertTrue("\($0)".contains("PERFLOOP_LOCK"), "\($0)")
    }
  }
}

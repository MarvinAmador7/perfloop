import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// `perfloop doctor` on this Mac's side, with every reading scripted: each state gives its line and its status.
final class DoctorMachineTests: XCTestCase {
  func probe(idle: Double? = 600, locked: Bool? = false, front: String? = "Finder", free: Int64? = 100_000_000_000, git: String? = nil, ignored: Bool = false,
             xctrace: String? = "/usr/bin/xctrace", devTools: Bool? = true, load: (Double, Int)? = (1, 8), arm: Bool = true, major: Int = 26) -> MachineProbe {
    var p = MachineProbe()
    p.os = { OperatingSystemVersion(majorVersion: major, minorVersion: 1, patchVersion: 0) }
    p.model = { "Mac16,10" }; p.arm64 = { arm }
    p.xctrace = { xctrace }; p.devTools = { devTools }
    p.idle = ScriptedIdleSource { IdleReading(idle: idle, frontmost: front, locked: locked) }
    p.freeBytes = { _ in free }; p.gitTop = { _ in git }; p.gitIgnored = { _ in ignored }; p.load = { load }
    return p
  }
  func report(_ p: MachineProbe, store: URL? = URL(fileURLWithPath: "/Users/me/.perfloop/notes")) -> Doctor.Report {
    var d = Doctor(); d.checkMachine(store: store, env: [:], probe: p); return Doctor.Report(lines: d.lines)
  }
  func status(_ r: Doctor.Report, _ check: String) -> Doctor.Status? { r.lines.first { $0.check == check }?.status }

  func testAFreeMacIsAllOk() {
    let r = report(probe())
    XCTAssertTrue(r.ok, r.text)
    #if os(macOS)
    XCTAssertFalse(r.lines.contains { $0.status != .ok }, r.text)
    XCTAssertTrue(r.text.contains("macOS 26.1 on Mac16,10"))
    #else
    XCTAssertEqual(r.lines.filter { $0.status != .ok }.map(\.check), ["platform"], "elsewhere: only the headless verbs")
    #endif
  }

  func testALockedScreenFails() {
    let r = report(probe(locked: true))
    XCTAssertFalse(r.ok)
    XCTAssertEqual(status(r, "screen"), .fail)
  }

  func testSomeoneUsingTheMacOrACallWarns() {
    XCTAssertEqual(status(report(probe(idle: 3)), "idle"), .warn)
    XCTAssertEqual(status(report(probe(front: "zoom.us")), "idle"), .warn)
    XCTAssertNil(status(report(probe(idle: nil, locked: nil)), "idle"), "unknown idle: no line, the gate says so when it waits")
  }

  func testDiskThresholds() {
    XCTAssertEqual(status(report(probe(free: 2_000_000_000)), "disk"), .fail)
    XCTAssertEqual(status(report(probe(free: 12_000_000_000)), "disk"), .warn)
    XCTAssertEqual(status(report(probe(free: 80_000_000_000)), "disk"), .ok)
  }

  func testAStoreInARepoFailsUnlessIgnored() {
    XCTAssertEqual(status(report(probe(git: "/Users/me/src/notes")), "store"), .fail)
    XCTAssertEqual(status(report(probe(git: "/Users/me/src/notes", ignored: true)), "store"), .warn)
  }

  func testOptionalToolsOnlyWarn() {
    let r = report(probe(xctrace: nil, devTools: false, load: (7, 8), arm: false))
    XCTAssertTrue(r.ok, r.text)
    for c in ["xctrace", "developer tools", "load"] { XCTAssertEqual(status(r, c), .warn, c) }
    #if os(macOS)
    XCTAssertEqual(status(r, "sampler"), .warn)
    #endif
  }

  func testOldMacOSFails() {
    #if os(macOS)
    XCTAssertEqual(status(report(probe(major: 13)), "macOS"), .fail)
    #endif
  }

  func testJSONIsDoctorV1() throws {
    let j = PLJSON.encode(report(probe(locked: true)))
    let v = try PLJSON.decode(JSONValue.self, from: Data(j.utf8))
    XCTAssertEqual(v["schema"]?.string, "perfloop.doctor/1")
    XCTAssertEqual(v["lines"]?.array?.first { $0["check"]?.string == "screen" }?["status"]?.string, "fail")
  }
}

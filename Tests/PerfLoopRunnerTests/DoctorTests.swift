import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// `perfloop doctor --bench`: the headless half of the adapter contract, on the fake adapter and broken copies of it.
final class DoctorTests: FakeBenchCase {
  func doctor(_ values: [String: String]) throws -> Doctor.Report {
    var d = Doctor()
    d.checkBench(try bench("doc-\(UUID().uuidString.prefix(6))", values), scratch: tmp.appendingPathComponent("doctor"))
    return Doctor.Report(lines: d.lines)
  }
  func line(_ r: Doctor.Report, _ check: String) -> Doctor.Line? { r.lines.first { $0.check == check } }

  func testAGoodAdapterPasses() throws {
    let r = try doctor([:])
    XCTAssertTrue(r.ok, r.text)
    XCTAssertEqual(line(r, "build stamp")?.status, .ok)
    XCTAssertEqual(line(r, "pairs")?.detail, "measured through the adapter's own ab")
    XCTAssertTrue(r.text.hasSuffix("doctor: nothing blocks the loop"))
  }

  func testUnstampedIsAFailWithItsFix() throws {
    let r = try doctor(["STAMP": "0"])
    XCTAssertFalse(r.ok)
    XCTAssertEqual(line(r, "build stamp")?.status, .fail)
    XCTAssertTrue(line(r, "build stamp")?.fix?.contains("PerfLoopStamp") == true)
  }

  func testAHashThatIsNotTheFilesIsAFail() throws {
    let r = try doctor(["HASH": String(repeating: "0", count: 64)])
    XCTAssertEqual(line(r, "build stamp")?.status, .fail)
    XCTAssertTrue(line(r, "build stamp")?.detail.contains("hashes to") == true)
  }

  func testAScenarioWhoseFixtureIsntListedIsAFail() throws {
    let r = try doctor(["STEP_FIXTURE": "crew71"])
    XCTAssertFalse(r.ok)
    let l = try XCTUnwrap(r.lines.first { $0.check == "scenario step" && $0.status == .fail })
    XCTAssertEqual(l.detail, "its fixture: unknown fixture 'crew71'; the manifest has crew17, swarm64")
    XCTAssertTrue(try doctor(["STEP_FIXTURE": "swarm64"]).ok)
  }

  func testAFileFixtureIsOffTheListAndWarnedWhenItIsntHere() throws {
    let r = try doctor(["STEP_FIXTURE": "file:/nonexistent/perfloop-fixture.json"])
    XCTAssertTrue(r.ok, r.text)
    let l = try XCTUnwrap(r.lines.first { $0.check == "scenario step" && $0.status == .warn }, r.text)
    XCTAssertTrue(l.detail.hasPrefix("fixture file:/nonexistent/perfloop-fixture.json: no readable file at /nonexistent/perfloop-fixture.json on this Mac"), l.detail)
    let s = try doctor(["STEP_FIXTURE": "s3:bucket/x", "SCHEMES": "file"])
    XCTAssertFalse(s.ok)
    XCTAssertEqual(s.lines.first { $0.check == "scenario step" && $0.status == .fail }?.detail,
                   "its fixture: fixture 's3:bucket/x': the adapter takes no s3: fixtures (the manifest has fixtureSchemes file:); its fixtures are crew17, swarm64")
  }

  func testDirtyIsAWarningNotAFail() throws {
    let r = try doctor(["DIRTY": "true"])
    XCTAssertTrue(r.ok)
    XCTAssertEqual(line(r, "clean build")?.status, .warn)
  }

  func testAnUnknownObjectiveIsAFail() throws {
    let r = try doctor(["OBJECTIVE": "fps"])
    XCTAssertFalse(r.ok)
    XCTAssertEqual(line(r, "scenario step")?.status, .fail)
    XCTAssertTrue(line(r, "scenario step")?.detail.contains("objective fps") == true)
  }

  func testNoDescribeIsAWarning() throws {
    let r = try doctor(["DESCRIBE": "0"])
    XCTAssertTrue(r.ok, r.text)
    XCTAssertEqual(line(r, "describe --json")?.status, .warn)
  }

  func testASnapshotGuardNeedsSnapdiff() throws {
    XCTAssertEqual(line(try doctor(["GUARDED": "1"]), "snapdiff")?.status, .ok)
    let r = try doctor(["GUARDED": "1", "VERBS": "list,describe,run"])
    XCTAssertFalse(r.ok)
    XCTAssertEqual(line(r, "snapdiff")?.status, .fail)
    XCTAssertEqual(line(r, "pairs")?.detail, "measured through two runs per pair (no ab)")
  }

  func testNotABench() {
    var d = Doctor()
    d.checkBench(tmp.appendingPathComponent("nothing-here").path, scratch: tmp)
    XCTAssertEqual(d.lines.first?.status, .fail)
  }

  func testTheOnePixelPNGIsAPNG() throws {
    let d = try XCTUnwrap(Data(base64Encoded: Doctor.onePixelPNG))
    XCTAssertEqual(Array(d.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  }
}

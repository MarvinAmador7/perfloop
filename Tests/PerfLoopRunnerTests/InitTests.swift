import Foundation
import XCTest
@testable import PerfLoopRunner

/// `perfloop init`: what it writes, what it refuses, the names and paths it derives. (Building the scaffold against
/// the package is checked by hand: it needs a full SwiftPM build.)
final class InitTests: XCTestCase {
  var tmp: URL!
  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-init-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

  func testNames() {
    XCTAssertEqual(Scaffold.typeName("Note Taker"), "NoteTaker")
    XCTAssertEqual(Scaffold.typeName("slow-list"), "SlowList")
    XCTAssertEqual(Scaffold.typeName("3d viewer"), "App3dViewer")
    XCTAssertEqual(Scaffold.appName("Note Taker"), "notetaker")
    XCTAssertEqual(Scaffold(app: "slow-list", dir: tmp, perfloop: "../perfloop").target, "SlowListBench")
  }

  func testWritesABenchAndProgramAndPrintsTheLines() throws {
    let w = try Scaffold(app: "Note Taker", dir: tmp, perfloop: "../../tools/perfloop").write()
    XCTAssertEqual(w.files.map { URL(fileURLWithPath: $0).lastPathComponent }, ["main.swift", "PROGRAM.md"])
    let main = try String(contentsOf: tmp.appendingPathComponent("Sources/NoteTakerBench/main.swift"), encoding: .utf8)
    XCTAssertTrue(main.contains("Bench(app: \"notetaker\", stamp: perfLoopBuildStamp)"))
    XCTAssertTrue(main.contains("bench.main()"))
    XCTAssertTrue(main.contains("\\(i)"), "interpolations survive the template")
    let program = try String(contentsOf: tmp.appendingPathComponent("PROGRAM.md"), encoding: .utf8)
    XCTAssertTrue(program.contains("export PERFLOOP_APP=notetaker"))
    XCTAssertTrue(program.contains("--bench .build/release/NoteTakerBench"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Package.swift").path), "an existing package is never edited")
    XCTAssertTrue(w.next.contains(".package(path: \"../../tools/perfloop\")"))
    XCTAssertTrue(w.next.contains(".plugin(name: \"PerfLoopStamp\", package: \"perfloop\")"))
  }

  func testPackageModeAndGitURLs() throws {
    var s = Scaffold(app: "notes", dir: tmp, target: "NotesPerf", perfloop: "https://example.com/perfloop.git")
    s.package = true
    _ = try s.write()
    let pkg = try String(contentsOf: tmp.appendingPathComponent("Package.swift"), encoding: .utf8)
    XCTAssertTrue(pkg.contains(".package(url: \"https://example.com/perfloop.git\", branch: \"main\")"))
    XCTAssertTrue(pkg.contains(".executableTarget(name: \"NotesPerf\""))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Sources/NotesPerf/main.swift").path))
  }

  func testNeverOverwrites() throws {
    try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Sources/NotesBench"), withIntermediateDirectories: true)
    try "mine".write(to: tmp.appendingPathComponent("Sources/NotesBench/main.swift"), atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try Scaffold(app: "notes", dir: tmp, perfloop: "x").write()) { XCTAssertTrue("\($0)".contains("never overwrites")) }
    XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("Sources/NotesBench/main.swift"), encoding: .utf8), "mine")
    XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("PROGRAM.md").path), "nothing is written when one file is refused")
  }

  func testPathsToThePackage() throws {
    let root = tmp.appendingPathComponent("repo/tools/perfloop"), app = tmp.appendingPathComponent("repo/apps/notes")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/release"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try "let package = Package(\n  name: \"PerfLoop\",\n)".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    XCTAssertEqual(Scaffold.packageRoot(of: root.appendingPathComponent(".build/release/perfloop").path)?.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
    XCTAssertNil(Scaffold.packageRoot(of: app.appendingPathComponent("perfloop").path))
    XCTAssertEqual(Scaffold.relativePath(from: app, to: root), "../../tools/perfloop")
    XCTAssertEqual(Scaffold.relativePath(from: root, to: root), ".")
  }
}

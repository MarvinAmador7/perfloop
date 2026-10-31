import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// The content-addressed store with a fake adapter: import (pre-stamp), add (stamped), lookup, gc.
final class StoreTests: FakeBenchCase {
  func testImportAPreStampBench() throws {
    let dir = try bench("old", ["STAMP": "0", "DESCRIBE": "0"])
    let e = try store.importBench(dir, commit: "c79350e", dirty: true, note: "H3: the first AppKit reel")
    XCTAssertFalse(e.build.stamp); XCTAssertEqual(e.build.commit, "c79350e"); XCTAssertTrue(e.build.dirty)
    XCTAssertEqual(e.build.note, "H3: the first AppKit reel")
    XCTAssertEqual(e.build.hash, FileHash.sha256(file: dir + "/FakeBench"))
    XCTAssertEqual(e.dir.lastPathComponent, String(e.build.hash!.dropFirst(7)))       // builds/<sha256>/
    XCTAssertTrue(FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("Fake_Res.bundle/res.txt").path))
    XCTAssertEqual(e.manifest?.source, "list")                                          // no describe: derived from list
    XCTAssertEqual(e.manifest?.scenario("switch")?.objective, "latencyMs")
    // Idempotent, and found by a prefix.
    XCTAssertEqual(try store.importBench(dir, commit: "c79350e", dirty: true, note: nil).dir.path, e.dir.path)
    XCTAssertEqual(try store.entry(String(e.build.hash!.dropFirst(7).prefix(10))).build.commit, "c79350e")
  }

  func testAddRefusesAnUnstampedBenchAndReadsTheStamp() throws {
    XCTAssertThrowsError(try store.add(try bench("nostamp", ["STAMP": "0"]))) { e in
      XCTAssertEqual((e as? PLError)?.code, 6); XCTAssertTrue("\(e)".contains("store import"))
    }
    let e = try store.add(try bench("stamped", ["COMMIT": "9bcd41a"]))
    XCTAssertTrue(e.build.stamp); XCTAssertEqual(e.build.commit, "9bcd41a"); XCTAssertFalse(e.build.dirty)
    XCTAssertEqual(e.manifest?.source, nil); XCTAssertEqual(e.manifest?.app, "fake-app")  // describe --json
    XCTAssertEqual(e.manifest?.knobs.first?.name, "reel.slide")
    XCTAssertEqual(try store.entry(e.build.hash!).executable, e.dir.appendingPathComponent("FakeBench").path)
  }

  func testLocateAndGC() throws {
    let home = tmp.appendingPathComponent("home")
    XCTAssertEqual(try Store.locate(store: nil, app: "x", env: ["PERFLOOP_HOME": home.path]).root.lastPathComponent, "x")
    XCTAssertThrowsError(try Store.locate(store: nil, app: nil, env: ["PERFLOOP_HOME": home.path]))   // no app yet
    let base = try baseline()
    XCTAssertEqual(try Store.locate(store: nil, app: nil, env: ["PERFLOOP_HOME": home.path]).root.path, store.root.path)  // the only one
    for i in 0..<4 { _ = try store.add(try bench("b\(i)", ["CPU": "\(30 + i)"])) }
    let removed = store.gc(keep: 2)
    XCTAssertEqual(removed.count, 2)                                    // the champion is kept although it is the oldest
    XCTAssertNoThrow(try store.entry(base.build.hash!))
    XCTAssertEqual(store.entries().count, 3)
  }

  func testDescribeFallsBackToList() throws {
    let a = Adapter(exe: try bench("nodescribe", ["DESCRIBE": "0"]) + "/FakeBench")
    XCTAssertNil(a.describeRaw()); XCTAssertEqual(a.manifest()?.source, "list")
    XCTAssertNotNil(Adapter(exe: try bench("describes") + "/FakeBench").describeRaw())
  }
}

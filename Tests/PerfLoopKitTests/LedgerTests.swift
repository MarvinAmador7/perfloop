import XCTest
@testable import PerfLoopKit

final class LedgerTests: XCTestCase {
  var dir: URL!
  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  func testAppendAndResumeAfterATornLine() throws {
    let l = Ledger(path: dir.appendingPathComponent("ledger.jsonl").path)
    try l.append(LedgerEntry(experiment: "0001", state: "built", build: "sha256:aa"))
    try l.append(LedgerEntry(experiment: "0001", state: "promising", objective: .init(before: 41.2, after: 16.9)))
    try l.append(LedgerEntry(experiment: "0002", state: "built"))
    // A crash mid-write leaves half a line: reading skips it, and the next append closes it before writing its own.
    let h = try XCTUnwrap(FileHandle(forWritingAtPath: l.path)); try h.seekToEnd(); try h.write(contentsOf: Data("{\"schema\":\"perfloop.led".utf8)); try h.close()
    try l.append(LedgerEntry(experiment: "0002", state: "rejected"))
    let text = try String(contentsOfFile: l.path, encoding: .utf8)
    XCTAssertEqual(text.split(separator: "\n").count, 5)
    XCTAssertEqual(l.entries().count, 4)
    XCTAssertEqual(l.latest()["0002"]?.state, "rejected")
    XCTAssertEqual(l.latest()["0001"]?.state, "promising")
    XCTAssertEqual(l.latest()["0001"]?.objective?.after, 16.9)
  }

  func testSessions() throws {
    let l = Ledger(path: dir.appendingPathComponent("ledger.jsonl").path)
    try l.append(LedgerEntry(experiment: "0001", state: "rejected"))
    try l.append(LedgerEntry(experiment: "-", state: "session"))
    try l.append(LedgerEntry(experiment: "0002", state: "built"))
    XCTAssertEqual(l.currentSession().map(\.experiment), ["-", "0002"])
    XCTAssertNil(l.latest()["-"])
  }

  func testChampionParentChain() {
    let base = Build(hash: "sha256:00", commit: "3a6b5b7", dirty: false, stamp: true)
    let c0 = Champion.baseline(build: base, merged: true)
    XCTAssertEqual(c0.mergedAncestor, "3a6b5b7"); XCTAssertEqual(c0.parents, [])
    let c1 = c0.succeeded(by: "0003", build: Build(hash: "sha256:03", commit: "e6d3625", dirty: false, stamp: true), objectives: ["step": 30])
    XCTAssertEqual(c1.parents, ["0000"]); XCTAssertEqual(c1.mergedAncestor, "3a6b5b7"); XCTAssertFalse(c1.merged)
    // Climbing on an unmerged champion (SPEC §7.5): the chain grows back to the merged one.
    let c2 = c1.succeeded(by: "0005", build: Build(hash: "sha256:05", commit: nil, dirty: false, stamp: true), objectives: ["step": 16.9, "switch": 153.2], knobs: ["reel.slide": "ca"])
    XCTAssertEqual(c2.parents, ["0003", "0000"]); XCTAssertEqual(c2.mergedAncestor, "3a6b5b7")
    XCTAssertEqual(c2.objectives, ["step": 16.9, "switch": 153.2]); XCTAssertEqual(c2.knobs, ["reel.slide": "ca"])
    XCTAssertEqual(c2.chain, "0005 ← 0003 ← 0000 ← main@3a6b5b7")
    // The owner merges 0005's PR: the chain restarts there.
    let m = c2.markMerged(at: "9bcd41a")
    XCTAssertEqual(m.parents, []); XCTAssertEqual(m.mergedAncestor, "9bcd41a")
    let c3 = m.succeeded(by: "0007", build: Build(hash: "sha256:07", commit: "abc", dirty: false, stamp: true), objectives: [:])
    XCTAssertEqual(c3.parents, ["0005"]); XCTAssertEqual(c3.mergedAncestor, "9bcd41a")
    XCTAssertEqual(try PLJSON.decode(Champion.self, from: Data(PLJSON.encode(c3).utf8)), c3)
  }
}

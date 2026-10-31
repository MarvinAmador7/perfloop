import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// A store in a temp directory and "builds" made from Fixtures/fake-adapter.sh: each is a copy with its own FAKE_
/// values, so its own sha256.
class FakeBenchCase: XCTestCase {
  static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-adapter.sh")
  var tmp: URL!
  var store: Store!
  var loop: Loop!
  var log: URL { tmp.appendingPathComponent("adapter.log") }

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    setenv("FAKE_LOG", log.path, 1)
    store = Store(root: tmp.appendingPathComponent("home/fake-app"))
    loop = Loop(store: store)
    loop.log = { _ in }
    loop.championFirst = { _, i in i % 2 == 0 }                     // AB, BA, AB, … in every stage
    loop.cwd = tmp.path
  }
  override func tearDownWithError() throws { unsetenv("FAKE_LOG"); try? FileManager.default.removeItem(at: tmp) }

  /// A bench directory holding `FakeBench` (+ a resource bundle, as SwiftPM lays one out).
  func bench(_ name: String, _ values: [String: String] = [:]) throws -> String {
    var text = try String(contentsOf: Self.script, encoding: .utf8)
    for (k, v) in values {
      text = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix("FAKE_\(k)=") ? "FAKE_\(k)=\(v)" : String($0) }.joined(separator: "\n")
    }
    text += "\n# build \(name)\n"
    let dir = tmp.appendingPathComponent("bench-\(name)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Fake_Res.bundle"), withIntermediateDirectories: true)
    try "r".write(to: dir.appendingPathComponent("Fake_Res.bundle/res.txt"), atomically: true, encoding: .utf8)
    let exe = dir.appendingPathComponent("FakeBench")
    try text.write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    return dir.path
  }

  func adapterCalls(_ verb: String) -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix(verb + " ") }
  }

  /// A merged champion at cpu 40 ms/step on step/crew17.
  @discardableResult
  func baseline(_ values: [String: String] = [:]) throws -> Store.Entry {
    let e = try store.add(try bench("base", ["CPU": "40", "COMMIT": "3a6b5b7"].merging(values) { $1 }))
    try loop.setChampion(build: e.build.hash!, merged: true, scenario: "step", fixture: "crew17")
    return e
  }
}

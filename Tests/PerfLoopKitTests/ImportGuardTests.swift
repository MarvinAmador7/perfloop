import XCTest

/// The genericity gate (SPEC §2.2): no capcomd module is imported under Sources. Same rule as
/// scripts/check-imports.sh, which CI runs on its own.
final class ImportGuardTests: XCTestCase {
  static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  static func offending(in dir: URL) -> [String] {
    let re = try! NSRegularExpression(pattern: #"^\s*(@testable\s+)?(@_exported\s+)?import\s+(class |struct |enum |func |protocol )?(Capcomd\w*|DeskBenchKit)\b"#, options: .anchorsMatchLines)
    var out: [String] = []
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for f in files {
      guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
      for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) { out.append("\(f.lastPathComponent): \(Range(m.range, in: text).map { String(text[$0]) } ?? "")") }
    }
    return out
  }

  func testNoCapcomdImportsUnderSources() {
    let src = Self.package.appendingPathComponent("Sources")
    XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("PerfLoopKit").path))
    XCTAssertEqual(Self.offending(in: src), [])
  }

  func testTheGuardCatchesOne() throws {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-guard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: d) }
    try "import Foundation\n@testable import CapcomdDesk\n// import CapcomdStore is a comment\nimport DeskBenchKit\n".write(to: d.appendingPathComponent("x.swift"), atomically: true, encoding: .utf8)
    XCTAssertEqual(Self.offending(in: d).count, 2)
    #if !os(Windows)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [Self.package.appendingPathComponent("scripts/check-imports.sh").path, d.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    XCTAssertEqual(p.terminationStatus, 1)
    #endif
  }
}

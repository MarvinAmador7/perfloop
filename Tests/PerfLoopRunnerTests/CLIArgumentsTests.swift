import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// The CLI refuses arguments a subcommand doesn't take before anything runs: an unknown flag, a valued flag without
/// its value, `--store DIR` passed as one argument (a zsh variable holding both: the store was silently the default
/// one), `--flag=value`, a stray positional. And every command line the MCP server builds passes.
final class CLIArgumentsTests: XCTestCase {
  func refused(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) -> String {
    do { try CLIArguments.check(argv); XCTFail("accepted \(argv)", file: file, line: line); return "" }
    catch let e as PLError { XCTAssertEqual(e.code, 1, file: file, line: line); return e.description }
    catch { XCTFail("\(error)", file: file, line: line); return "" }
  }

  func testAFlagAndItsValueAsOneArgumentIsRefused() {
    let t = refused(["store", "list", "--store /tmp/elsewhere"])
    XCTAssertTrue(t.hasPrefix("unknown argument '--store /tmp/elsewhere' for perfloop store list: a flag and its value are two arguments ('--store' '/tmp/elsewhere')"), t)
    XCTAssertTrue(t.hasSuffix("\nusage: perfloop store list [--json]"), t)
    _ = refused(["exp", "new", "h", "--bench b", "--no-lock --no-wait"])
    XCTAssertTrue(refused(["exp", "new", "h", "--bench=b"]).contains("write '--bench' and its value as two arguments"))
  }

  func testUnknownFlagsMissingValuesAndStrayPositionalsAreRefused() {
    XCTAssertTrue(refused(["exp", "new", "h", "--bnch", "x"]).hasPrefix("unknown argument '--bnch' for perfloop exp new\nusage: perfloop exp new"))
    XCTAssertTrue(refused(["store", "list", "--force"]).hasPrefix("unknown argument '--force' for perfloop store list"), "an owner flag is no exception")
    XCTAssertTrue(refused(["run", "champion", "--reps"]).hasPrefix("--reps needs a value (perfloop run)"))
    XCTAssertTrue(refused(["exp", "new", "h", "--store", "--app", "x"]).hasPrefix("--store needs a value"), "a flag never becomes a value")
    XCTAssertTrue(refused(["exp", "screen", "0001", "0002"]).hasPrefix("unexpected argument '0002' for perfloop exp screen\nusage: perfloop exp screen ID"))
    XCTAssertTrue(refused(["champion", "foo"]).hasPrefix("unexpected argument 'foo' for perfloop champion"))
    XCTAssertTrue(refused(["ledger", "--", "x"]).hasPrefix("unknown argument '--' for perfloop ledger"))
    XCTAssertTrue(refused(["--store", "/s", "explain", "exp/1", "exp/2"]).contains("unexpected argument 'exp/2' for perfloop explain"), "the store first, then the command")
  }

  func testWhatTheDocsAndTheWalkthroughRunPasses() throws {
    for argv in [
      ["doctor", "--bench", "b"], ["store", "add", "b"], ["store", "list", "--json"], ["champion", "set", "h", "--merged", "--scenario", "select", "--fixture", "rows1000", "--note", "SlowList as it is"],
      ["exp", "new", "h", "--build-cmd", "swift build", "--bench", "b", "--json", "--runner", "ssh://u@m", "--idle", "60"], ["exp", "new", "h", "--knobs", "a=b", "--set", "k=v", "--set", "x=y"],
      ["exp", "screen", "0001", "--runner", "local", "--lock", "/l", "--no-wait", "--max-load", "40", "--quiet-timeout", "10", "--require-quiet"],
      ["exp", "full", "1", "--force"], ["exp", "promote", "1", "--owner", "--allow-dirty", "--pr", "u"], ["exp", "new", "h", "--guard-tolerance", "0.1"],
      ["exp", "status"], ["exp", "status", "1"], ["explain", "exp/1"], ["ledger"], ["champion"], ["guards", "--exp", "1", "--guard-tolerance", "0.1", "--owner"],
      ["run", "champion", "--scenario", "s", "--reference", "t", "--reps", "2", "--no-lock"], ["baseline", "s", "--bench", "b", "--reps", "5"],
      ["queue", "add", "1", "--stage", "full", "--runner", "ssh://u@m"], ["queue", "run", "--runner", "local", "--until", "07:00", "--idle", "120", "--force"], ["queue"],
      ["runner", "check", "ssh://u@m", "--accept-new-host-key", "--remote-env", "A=B", "--launch", "direct"],
      ["sweep", "select", "--set", "rows=100..5000/500", "--budget-ms", "8.3", "--dry-run"], ["sweep", "show", "d"], ["gestures", "list", "a.json", "b.json", "--dir", "d"],
      ["lock", "--label", "me", "--", "bench", "ab", "--a", "x", "--anything"], ["lock", "--json"], ["mcp", "--app", "a", "--lock", "/l"],
      ["diff", "champion", "exp/1", "--allow-stale"], ["profile", "exp/1", "--template", "hitches", "--keep-trace"], ["init", "--app", "A", "--package"],
      ["unknown-command", "--whatever"], [],
    ] { XCTAssertNoThrow(try CLIArguments.check(argv), "\(argv)") }
  }

  func testHelpPrintsTheUsageAndRunsNothing() throws {
    XCTAssertEqual(try CLIArguments.check(["exp", "full", "--help"]), .help("usage: perfloop exp full ID [runner flags]"))
    XCTAssertEqual(try CLIArguments.check(["sweep", "--help"]), .ok, "sweep prints its own, longer help")
  }

  /// Every tool the MCP server offers builds a command line the CLI takes.
  /// Flags added by other verbs reach this table too: `exp new --expect`, `exp screen --more [N]`.
  func testExpectAndMoreAreTaken() throws {
    for argv in [["exp", "new", "h", "--build", "abc", "--expect", "same"], ["exp", "screen", "0002", "--more"], ["exp", "screen", "0002", "--more", "5"],
                 ["exp", "screen", "0002", "--more", "--runner", "local-idle"], ["exp", "new", "h", "--build", "abc", "--expect", "same", "--expect-look", "footer,list"],
                 ["run", "champion", "--scenario", "s", "--set", "appearance=dark", "--expect-look", "footer"], ["baseline", "s", "--build", "abc", "--set", "appearance=dark"]] {
      XCTAssertNoThrow(try CLIArguments.check(argv), "\(argv)")
    }
    XCTAssertThrowsError(try CLIArguments.check(["exp", "new", "h", "--build", "abc", "--expect"]))
    XCTAssertThrowsError(try CLIArguments.check(["exp", "screen", "0002", "--more", "lots"]))
  }

  func testEveryMCPToolBuildsACommandTheCLITakes() throws {
    let s = MCPServer(cli: "/bin/false", baseArgs: ["--app", "demo"], jobsDir: FileManager.default.temporaryDirectory, lock: "/tmp/l")
    let samples: [String: JSONValue] = ["id": .string("0007"), "target": .string("exp/0007"), "hypothesis": .string("h"), "bench": .string("/b/Bench"),
                                        "build_cmd": .string("swift build"), "knobs": .string("a=b"), "scenario": .string("s"), "fixture": .string("f"),
                                        "behaviour_change": .bool(true), "screen": .bool(true), "runner": .string("local-idle"), "pr": .string("u"), "note": .string("n"),
                                        "template": .string("time"), "a": .string("champion"), "b": .string("exp/0003"), "set": .array([.string("rows=1..4")]),
                                        "reps": .number(2), "reference": .string("r"), "build": .string("abc123"), "stage": .string("full"), "wait_s": .number(0),
                                        "expect": .string("same"), "more": .number(3), "appearance": .string("dark"), "expect_look": .string("footer,list")]
    var checked = 0
    for t in s.tools where !["job", "jobs", "cancel_job"].contains(t.name) {
      for variant in [t.properties.keys.filter { $0 != "build" || t.properties["bench"] == nil }, Array(t.required)] {
        var a: [String: JSONValue] = [:]
        for k in variant { a[k] = samples[k] ?? .string("x") }
        if t.name == "queue_add", a["runner"] != nil { a["runner"] = .string("ssh://u@m") }
        if t.name == "baseline", a["bench"] == nil { a["bench"] = samples["bench"] }
        if t.name == "new_experiment", variant.count == t.required.count { a["screen"] = .bool(false) }
        let argv = try t.args(a) + s.baseArgs
        XCTAssertNoThrow(try CLIArguments.check(argv), "\(t.name): \(argv)")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 30)
  }

  /// The built `perfloop` itself: `--store DIR` as one argument stops before any store is made or read.
  func testTheCLIRefusesBeforeTouchingAStore() throws {
    let exe = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("perfloop")
    #if os(Linux)
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/perfloop").path
    #else
    let path = exe.path
    #endif
    guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("perfloop isn't built next to the tests (swift build first)") }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-cli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = home.appendingPathComponent("mine")
    let p = Process(); p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["store", "add", "/nonexistent/bench", "--store \(store.path)"]
    var env = ProcessInfo.processInfo.environment; env["PERFLOOP_HOME"] = home.path; env["PERFLOOP_LOCK"] = "off"; env["PERFLOOP_OWNER"] = nil; p.environment = env
    let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(p.terminationStatus, 1)
    XCTAssertTrue(text.contains("unknown argument '--store \(store.path)' for perfloop store add"), text)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "no store was made")
  }
}

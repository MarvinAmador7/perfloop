import Foundation
import XCTest
@testable import PerfLoopKit
@testable import PerfLoopRunner

/// `perfloop mcp` against a fake CLI: the protocol, the tools' schemas, jobs the agent polls instead of sleeping, the
/// owner's flags out of reach, and nothing left running when the session ends.
final class MCPTests: XCTestCase {
  static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
  var tmp: URL!
  var log: URL { tmp.appendingPathComponent("cli.log") }
  var server: MCPServer!

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perfloop-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    server = MCPServer(cli: Self.fixtures.appendingPathComponent("fake-cli.sh").path, baseArgs: ["--app", "demo"], jobsDir: tmp.appendingPathComponent("jobs"),
                       lock: tmp.appendingPathComponent("window.lock").path)
    server.env = ["FAKE_CLI_LOG": log.path, "FAKE_CLI_SLEEP": "1"]
  }
  override func tearDownWithError() throws { server.shutdown(); try? FileManager.default.removeItem(at: tmp) }

  var n = 0
  func rpc(_ method: String, _ params: JSONValue = .object([:])) throws -> JSONValue {
    n += 1
    let line = PLJSON.line(JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(n)), "method": .string(method), "params": params]))
    let out = try XCTUnwrap(server.handle(line))
    XCTAssertFalse(out.contains("\n"), "one message per line")
    let v = try PLJSON.decode(JSONValue.self, from: Data(out.utf8))
    XCTAssertEqual(v["id"]?.double, Double(n))
    return v
  }
  func call(_ tool: String, _ args: [String: JSONValue] = [:]) throws -> (text: String, isError: Bool) {
    let r = try rpc("tools/call", .object(["name": .string(tool), "arguments": .object(args)]))
    let res = try XCTUnwrap(r["result"], "\(r)")
    return (res["content"]?[0]?["text"]?.string ?? "", res["isError"]?.bool ?? false)
  }
  func calls() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
  /// A job's child logs its arguments once it has started: wait for that line.
  func called(_ prefix: String) -> Bool {
    let until = Date().addingTimeInterval(10)
    while Date() < until { if calls().contains(where: { $0.hasPrefix(prefix) }) { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return false
  }

  func testHandshakeAndToolSchemas() throws {
    let i = try rpc("initialize", .object(["protocolVersion": .string("2025-03-26"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("t")])]))
    XCTAssertEqual(i["result"]?["protocolVersion"]?.string, "2025-03-26")
    XCTAssertEqual(i["result"]?["serverInfo"]?["name"]?.string, "perfloop")
    XCTAssertNotNil(i["result"]?["capabilities"]?["tools"])
    XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no answer")
    let tools = try XCTUnwrap(try rpc("tools/list")["result"]?["tools"]?.array)
    let names = tools.compactMap { $0["name"]?.string }
    for t in ["status", "explain", "new_experiment", "screen", "full", "promote", "profile", "diff", "sweep", "job", "cancel_job"] { XCTAssertTrue(names.contains(t), t) }
    XCTAssertTrue(tools.allSatisfy { $0["inputSchema"]?["type"]?.string == "object" && $0["description"]?.string?.isEmpty == false })
    // The owner's flags are no tool's argument.
    let text = PLJSON.encode(tools)
    for f in ["force", "owner", "guard-tolerance", "guard_tolerance", "allow-dirty", "allow_dirty", "allow-stale"] { XCTAssertFalse(text.contains("\"\(f)\""), f) }
    XCTAssertEqual(try rpc("nope")["error"]?["code"]?.double, -32601)
    XCTAssertEqual(server.handle("not json").flatMap { try? PLJSON.decode(JSONValue.self, from: Data($0.utf8)) }?["error"]?["code"]?.double, -32700)
  }

  func testHeadlessToolsAnswerAtOnce() throws {
    let s = try call("status")
    XCTAssertFalse(s.isError); XCTAssertTrue(s.text.contains("no open experiments"))
    XCTAssertEqual(calls().last, "exp status --app demo")
    XCTAssertEqual(try call("explain", ["id": .string("0007")]).text, "ok: explain exp/0007 --app demo")
    let p = try call("promote", ["id": .string("9999")])
    XCTAssertTrue(p.isError); XCTAssertTrue(p.text.contains("refused: not won"), "stderr reaches the agent")
    XCTAssertEqual(try call("diff", ["a": .string("champion"), "b": .string("exp/0003")]).text, "ok: diff champion exp/0003 --app demo")
  }

  func testValuesCantBecomeFlags() throws {
    for (tool, args) in [("explain", ["id": JSONValue.string("--force")]), ("promote", ["id": .string("0001 --owner")]),
                         ("new_experiment", ["hypothesis": .string("--allow-dirty")]), ("screen", ["id": .string("0001"), "runner": .string("--force")]),
                         ("status", ["id": .string("1"), "owner": .bool(true)]), ("diff", ["a": .string("-x"), "b": .string("champion")])] {
      let r = try call(tool, args)
      XCTAssertTrue(r.isError, "\(tool) \(args)"); XCTAssertTrue(r.text.contains("refused") || r.text.contains("unknown argument"), r.text)
    }
    XCTAssertTrue(calls().isEmpty, "nothing ran")
  }

  func testStagesAreJobsTheAgentPollsAndNothingOutlivesTheSession() throws {
    let start = try call("screen", ["id": .string("0001")])
    XCTAssertFalse(start.isError, start.text); XCTAssertTrue(start.text.hasPrefix("started job j1 (screen)"), start.text)
    XCTAssertTrue(called("exp screen 0001 --runner local --lock \(tmp.appendingPathComponent("window.lock").path) --app demo"), "\(calls())")
    let early = try call("job", ["id": .string("j1"), "wait_s": .number(0)])
    XCTAssertTrue(early.text.contains("running"), early.text)
    let done = try call("job", ["id": .string("j1"), "wait_s": .number(20)])
    XCTAssertTrue(done.text.contains("finished, exit 0"), done.text); XCTAssertTrue(done.text.contains("exp 0001 · promising")); XCTAssertTrue(done.text.contains("pair 1"))
    XCTAssertTrue(try call("jobs").text.contains("j1 screen exit 0"))
    // The idle-gated runner and a spare Mac, by name.
    _ = try call("full", ["id": .string("2"), "runner": .string("local-idle")])
    XCTAssertTrue(called("exp full 2 --runner local --idle 120"), "\(calls())")
    _ = try call("full", ["id": .string("3"), "runner": .string("ssh://mar@mini.local")])
    XCTAssertTrue(called("exp full 3 --runner ssh://mar@mini.local"), "\(calls())")
    XCTAssertTrue(try call("profile", ["target": .string("exp/3"), "runner": .string("ssh://mar@mini.local")]).isError, "profiles record on this Mac")
    // A long job: cancelled, and the session's end kills whatever still runs.
    server.env["FAKE_CLI_SLEEP"] = "30"
    _ = try call("full", ["id": .string("4")])
    let j4 = try XCTUnwrap(server.jobs.last); XCTAssertTrue(j4.running)
    XCTAssertTrue(try call("cancel_job", ["id": .string(j4.id)]).text.contains("stopped"))
    XCTAssertFalse(j4.running)
    _ = try call("full", ["id": .string("5")])
    let j5 = try XCTUnwrap(server.jobs.last)
    let input = Pipe(), output = Pipe()
    let done5 = expectation(description: "served")
    DispatchQueue.global().async { self.server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting); done5.fulfill() }
    input.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":99,"method":"ping"}"# + "\n").utf8))
    try input.fileHandleForWriting.close()
    wait(for: [done5], timeout: 15)
    XCTAssertFalse(j5.process.isRunning, "the session ended: its jobs end too")
    XCTAssertTrue(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).contains(#""id":99"#))
  }
}

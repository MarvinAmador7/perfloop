import Foundation
import PerfLoopKit

/// `perfloop init`: the files an app needs to put PerfLoop on itself. A bench target that builds as it is (one
/// scenario on a placeholder view, to be pointed at the app's own), the agent's procedure (PROGRAM.md), and the
/// Package.swift lines to add; with `--package`, a standalone Package.swift too. Never overwrites a file.
public struct Scaffold {
  public var app: String
  public var dir: URL
  /// The bench's executable target, `<App>Bench` by default.
  public var target: String
  /// Where the PerfLoop package is, for the dependency line: a path (relative to `dir` when it can be) or a git URL.
  public var perfloop: String
  /// Write a Package.swift for a standalone bench package.
  public var package = false

  public init(app: String, dir: URL, target: String? = nil, perfloop: String) {
    self.app = app; self.dir = dir; self.perfloop = perfloop
    self.target = target ?? (Self.typeName(app) + "Bench")
  }

  /// The PerfLoop package this `perfloop` was built from: the nearest parent of the executable with a Package.swift
  /// naming the package PerfLoop (`.build/release/perfloop` in a checkout).
  public static func packageRoot(of exe: String) -> URL? {
    var u = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
    while u.path != "/" {
      let m = u.appendingPathComponent("Package.swift")
      if let t = try? String(contentsOf: m, encoding: .utf8), t.contains("name: \"PerfLoop\"") { return u }
      u = u.deletingLastPathComponent()
    }
    return nil
  }

  /// `to` relative to `from` (both directories), for a Package.swift dependency path.
  public static func relativePath(from: URL, to: URL) -> String {
    let a = from.standardizedFileURL.resolvingSymlinksInPath().pathComponents, b = to.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    var i = 0
    while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
    if i <= 1 { return to.path }                         // nothing shared but the root: keep it absolute
    let up = Array(repeating: "..", count: a.count - i), down = Array(b[i...])
    let r = (up + down).joined(separator: "/")
    return r.isEmpty ? "." : r
  }

  /// "slow-list" → "SlowList".
  public static func typeName(_ s: String) -> String {
    let parts = s.split { !$0.isLetter && !$0.isNumber }
    let t = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    return t.first?.isLetter == true ? t : "App" + t
  }
  /// "SlowList" → "slowlist": the app name the store and the manifest use.
  public static func appName(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }

  public struct Written { public var files: [String]; public var next: String }

  public func write() throws -> Written {
    let fm = FileManager.default
    var files: [(String, String)] = [("Sources/\(target)/main.swift", benchSource), ("PROGRAM.md", program)]
    if package { files.insert(("Package.swift", packageSwift), at: 0) }
    for (rel, _) in files where fm.fileExists(atPath: dir.appendingPathComponent(rel).path) {
      throw PLError.refused("\(dir.appendingPathComponent(rel).path) exists: init never overwrites (move it, or pass another --dir / --target)")
    }
    for (rel, text) in files {
      let u = dir.appendingPathComponent(rel)
      try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: u, atomically: true, encoding: .utf8)
    }
    return Written(files: files.map { dir.appendingPathComponent($0.0).path }, next: nextSteps)
  }

  var dependencyLine: String {
    perfloop.hasPrefix("http") || perfloop.hasPrefix("git@") ? ".package(url: \"\(perfloop)\", branch: \"main\")" : ".package(path: \"\(perfloop)\")"
  }

  /// The lines to add to an existing Package.swift.
  public var snippet: String {
    """
      // dependencies:
      \(dependencyLine),
      // targets: the bench (keep the app's own targets as they are; add PerfLoopProbe to the app's target if its views
      // call Probe.body or it has knobs)
      .executableTarget(name: "\(target)",
                        dependencies: [/* "YourAppKit", */ .product(name: "PerfLoopHost", package: "perfloop"), .product(name: "PerfLoopProbe", package: "perfloop")],
                        plugins: [.plugin(name: "PerfLoopStamp", package: "perfloop")]),
    """
  }

  var packageSwift: String {
    """
    // swift-tools-version:5.9
    import PackageDescription

    // \(app)'s PerfLoop bench (perfloop init). Add your app's library target to the bench's dependencies, and
    // PerfLoopProbe to the app's target if its views call Probe.body or it has knobs.
    let package = Package(
      name: "\(Self.typeName(app))Bench",
      platforms: [.macOS(.v14)],
      dependencies: [\(dependencyLine)],
      targets: [
        .executableTarget(name: "\(target)",
                          dependencies: [.product(name: "PerfLoopHost", package: "perfloop"), .product(name: "PerfLoopProbe", package: "perfloop")],
                          plugins: [.plugin(name: "PerfLoopStamp", package: "perfloop")]),
      ])

    """
  }

  var benchSource: String {
    let name = Self.appName(app)
    return """
    import AppKit
    import SwiftUI
    import PerfLoopHost
    import PerfLoopProbe
    // import YourAppKit       // the module that has your app's views and model

    // \(app)'s PerfLoop bench (perfloop init). The contract with the runner is tools/perfloop/ADAPTER.md; PerfLoopHost
    // answers it. This file says what to measure: fixtures (the data), scenarios (what the user does), knobs, guards.
    // An agent running the loop never edits this file inside an experiment (AGENTS.md): it is how builds are judged.

    let bench = Bench(app: "\(name)", stamp: perfLoopBuildStamp)   // the PerfLoopStamp plugin writes perfLoopBuildStamp
    bench.appModules = ["\(Self.typeName(app))"]                  // your modules' name prefix: their frames are "ours"
    bench.fixture("small", summary: "a small document", params: ["items": "100"], parametric: ["items": 1...10_000])
    bench.fixture("large", summary: "a large one: a win must not be worse here", params: ["items": "2000"], parametric: ["items": 1...10_000])
    // bench.knobs { [YourKnobs.layout] }                       // static let layout = Knob("list.layout", default: "stack", choices: ["stack", "grid"])

    /// The placeholder the scenario shows: replace it with your app's real view on fixture data.
    final class PlaceholderModel: ObservableObject { @Published var selected = 0; let items: [String]; init(_ n: Int) { items = (0..<n).map { "Item \\($0)" } } }
    struct PlaceholderView: View {
      @ObservedObject var model: PlaceholderModel
      var body: some View {
        Probe.body("Placeholder")
        return List(model.items.indices, id: \\.self) { i in
          Text(model.items[i]).fontWeight(i == model.selected ? .bold : .regular)
        }
      }
    }

    bench.scenario("select", summary: "Select items one after another", guards: ["checks", "snapshot-diff"], params: ["steps": "8"],
                   secondFixture: "large") { run in
      let model = PlaceholderModel(run.fixture.int("items", 100))         // your model, on fixture data
      try await run.show(PlaceholderView(model: model))                  // or run.show(view: someNSView)
      let n = run.int("steps", 8)
      for i in 0..<n {
        await run.step("select#\\(i)") { model.selected = i }              // one thing the user does; measured to rest
      }
      run.check("landed", model.selected == n - 1, "selected \\(model.selected)")   // what must be true afterwards
    }

    // A guard of your own, judged after each rep with the window up (list it in a scenario's guards):
    // bench.guard("rows-built") { run, params in
    //   let n = run.bodyIDs(of: "Row").count
    //   return GuardResult(name: "rows-built", pass: n >= 10, detail: "\\(n) rows built")
    // }

    bench.main()

    """
  }

  var nextSteps: String {
    let bench = ".build/release/\(target)"
    return """
    next:
      1. \(package ? "" : "add to Package.swift:\n\(snippet)\n      then ")point the scenario at your app's real view and model (Sources/\(target)/main.swift)
      2. commit, then: swift build -c release --product \(target)
      3. perfloop doctor --bench \(bench)
      4. \(bench) run select --reps 1                       (opens a window for a few seconds)
      5. export PERFLOOP_APP=\(Self.appName(app)); perfloop store add \(bench)
         perfloop champion set <hash from store add> --merged
      6. hand PROGRAM.md and tools/perfloop/AGENTS.md to your coding agent
    """
  }

  var program: String {
    let bench = ".build/release/\(target)"
    return """
    # PROGRAM: making \(app) faster with perfloop

    You are a coding agent improving \(app)'s performance. This file is your procedure; tools/perfloop/AGENTS.md has the
    rules every PerfLoop agent follows. The bench (`\(target)`) measures; `perfloop` decides and remembers. You change
    the app's code, one idea at a time, and keep a change only when the loop says it won and nothing visible broke.

    ## Setup (once; the owner sets the champion)

    ```sh
    export PERFLOOP_APP=\(Self.appName(app))      # the store: ~/.perfloop/\(Self.appName(app)) (never inside the repo)
    swift build -c release --product \(target)
    perfloop doctor --bench \(bench)
    perfloop store add \(bench)
    perfloop champion set <hash> --merged --scenario select --fixture small
    ```

    ## The loop

    1. `perfloop session start`, then `perfloop exp status`.
    2. Look: the champion's newest `explain.txt` (or `\(bench) run select --reps 1`) says where the main thread's time
       went: the worst stretch, our frames, framework frames and the app frame they ran under, the bodies and the
       state changes they followed.
    3. One hypothesis, one sentence, naming the cost and why the change removes it.
    4. Change the app's code (never the bench, its scenarios, fixtures or guards), commit, then
       `perfloop exp new "<hypothesis>" --build-cmd "swift build -c release --product \(target)" --bench \(bench)`.
       For a knob: `perfloop exp new "<hypothesis>" --knobs name=value`.
    5. Read the experiment's explain.txt; its last line is the next command (`exp full`, `exp promote`, or drop it).
    6. Stop when `exp status` prints a `stop:` line, and report from `perfloop ledger`.

    ## Scenarios

    | Scenario | Objective (lower is better) | Budget |
    |---|---|---|
    | `select` | `mainThreadCpuMsPerStep` | (yours: e.g. no frame held past its vsync) |

    ## What you may not touch inside an experiment

    Sources/\(target)/ (scenarios, fixtures, guards), this file, the store under ~/.perfloop. Never commit `.trace`
    files, stores, or anything with secrets.

    """
  }
}

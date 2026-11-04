import Foundation
import PerfLoopKit
import PerfLoopRunner

/// `perfloop gestures list`: the recorded and synthetic gestures a gesture-replay scenario can take (CAPABILITIES.md
/// C9): `perfloop.gesture/1` files in the store's `gestures/` (where an adapter's recorder writes by default), in each
/// `--dir`, and given by name; with `--bench`, the ones the adapter has built in (its manifest's `gestures`).
enum GesturesCommand {
  static let usage = """
  usage: perfloop gestures list [FILE…] [--dir DIR]… [--bench PATH] [--store DIR | --app NAME] [--json]
    gesture files (perfloop.gesture/1) in the store's gestures/ folder and each --dir, and the FILEs named; with
    --bench, the adapter's built-in ones. Replay one: exp new … --scenario swipe --set gesture=FILE (or the adapter's own,
    BENCH run SCENARIO --set gesture=FILE; record one by hand: BENCH record-gesture SCENARIO). Exit 1 when a named FILE isn't a gesture that can be replayed.
  """

  static func run(_ args: Args) throws -> Int32 {
    guard args[1] == "list" || args[1] == nil else { throw PLError.usage(usage) }
    if args.has("help") { out(usage); return 0 }
    var dirs = args.all("dir").map(expand)
    if let s = try? Store.locate(store: args.one("store"), app: args.one("app")) { dirs.insert(s.root.appendingPathComponent("gestures").path, at: 0) }
    let files = Array(args.positional.dropFirst(2)).map(expand)
    let found = GestureFile.scan(dirs: dirs, files: files)
    var builtIn: [String] = []
    if let b = args.one("bench") {
      let a = Adapter(exe: try Store.executable(at: b, named: args.one("exe")).path)
      builtIn = a.manifest()?.gestures ?? []
    }
    if args.has("json") {
      struct L: Codable { var schema = "perfloop.gestures/1"; var dirs: [String]; var gestures: [GestureFile]; var builtIn: [String] }
      out(PLJSON.encode(L(dirs: dirs, gestures: found, builtIn: builtIn)))
    } else {
      for g in found { out(g.line) }
      if found.isEmpty { out("no gesture files in " + (dirs.isEmpty ? "(no folder: --dir DIR, or a store)" : dirs.joined(separator: ", "))) }
      if !builtIn.isEmpty { out("built into the adapter: " + builtIn.joined(separator: ", ")) }
    }
    return found.contains { !$0.problems.isEmpty && files.contains($0.path) } ? 1 : 0
  }

  static func expand(_ p: String) -> String { p == "~" || p.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst() : p }
}

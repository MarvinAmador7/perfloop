import Foundation

/// Every `perfloop` subcommand's arguments, checked before the command runs (before any store, lock or runner is
/// touched): a flag the subcommand doesn't take, a valued flag without its value, and a positional argument it doesn't
/// take are refused with the subcommand's usage. A typo used to be ignored, and `--store DIR` given as one argument (a
/// shell variable holding both, which zsh doesn't split) left the store unset, so the command ran on the default store.
public enum CLIArguments {
  public struct Spec {
    /// "exp new": the command words.
    public var command: String
    public var usage: String
    public var valued: Set<String>
    public var flags: Set<String>
    /// How many positional arguments may follow the command words.
    public var positional: ClosedRange<Int>
    /// Parses its own flags past what is checked here (`lock`'s command after `--`, `sweep --help`).
    public var ownHelp = false
  }

  /// Every subcommand takes these: which store, and JSON output or help.
  static let globalValued: Set<String> = ["store", "app"]
  static let globalFlags: Set<String> = ["json", "help"]
  /// The runner's flags (`useRunner`, `runnerOptions` in main.swift), for every verb that runs reps.
  static let runnerValued: Set<String> = ["runner", "idle", "idle-from", "busy-apps", "lock", "launch", "remote-env", "max-load", "quiet-timeout"]
  static let runnerFlags: Set<String> = ["no-lock", "no-wait", "require-quiet", "accept-new-host-key"]

  static func spec(_ command: String, _ usage: String, valued: Set<String> = [], flags: Set<String> = [], positional: ClosedRange<Int> = 0...0,
                   runner: Bool = false, ownHelp: Bool = false) -> Spec {
    // `exp … --guard-tolerance` passes here so that the owner's gate, then the exp verbs' own refusal, answer it.
    Spec(command: command, usage: "usage: perfloop " + usage, valued: valued.union(globalValued).union(runner ? runnerValued : []).union(command.hasPrefix("exp ") ? ["guard-tolerance"] : []),
         flags: flags.union(globalFlags).union(runner ? runnerFlags : []), positional: positional, ownHelp: ownHelp)
  }

  public static let specs: [Spec] = [
    spec("help", "help"),
    spec("-h", "help"),
    spec("init", "init --app NAME [--dir DIR] [--target NAME] [--perfloop PATH|URL] [--package]", valued: ["app", "dir", "target", "perfloop"], flags: ["package"], positional: 0...1),
    spec("doctor", "doctor [--bench PATH] [--exe NAME] [--json]", valued: ["bench", "exe", "idle-from"], positional: 0...1),
    spec("describe", "describe --bench PATH [--exe NAME]", valued: ["bench", "exe"], positional: 0...1),
    spec("store import", "store import DIR --commit SHA [--dirty] --note \"…\" [--exe NAME]", valued: ["commit", "note", "exe"], flags: ["dirty"], positional: 1...1),
    spec("store add", "store add PATH [--exe NAME]", valued: ["exe"], positional: 1...1),
    spec("store list", "store list [--json]"),
    spec("store gc", "store gc [--keep N] [--traces]", valued: ["keep"], flags: ["traces"]),
    spec("champion", "champion [--json]"),
    spec("champion set", "champion set BUILD [--merged] [--scenario S] [--fixture F] [--note \"…\"]", valued: ["scenario", "fixture", "note"], flags: ["merged"], positional: 1...1),
    spec("champion merged", "champion merged SHA [--main REF]", valued: ["main"], positional: 1...1),
    spec("exp new", "exp new \"<hypothesis>\" [--bench PATH | --build-cmd CMD --bench PATH | --build HASH | --knobs k=v,…] [--scenario S] [--fixture F] "
         + "[--second-fixture F] [--set k=v] [--via ab|run] [--behaviour-change] [--patch FILE] [--no-screen] [--against ID] [--expect faster|same] [--exe NAME] [runner flags]",
         valued: ["bench", "exe", "build-cmd", "build", "scenario", "fixture", "second-fixture", "knobs", "set", "via", "patch", "against", "expect"],
         flags: ["behaviour-change", "behavior-change", "no-screen"], positional: 1...1, runner: true),
    spec("exp status", "exp status [ID]", positional: 0...1),
    spec("exp screen", "exp screen ID [--more [N]] [runner flags]", flags: ["more"], positional: 1...1, runner: true),
    spec("exp full", "exp full ID [runner flags]", flags: ["force", "owner"], positional: 1...1, runner: true),
    spec("exp promote", "exp promote ID [--pr URL]", valued: ["pr"], flags: ["owner", "allow-dirty"], positional: 1...1),
    spec("exp abandon", "exp abandon ID [--note \"…\"]", valued: ["note"], positional: 1...1),
    spec("exp replay", "exp replay PLAN.json [--dry-run | --go] [runner flags]", flags: ["dry-run", "go"], positional: 1...1, runner: true),
    spec("guards", "guards --exp ID [runner flags]", valued: ["exp", "guard-tolerance"], flags: ["owner"], positional: 0...1, runner: true),
    spec("explain", "explain exp/ID|run/ID|SWEEP", positional: 1...1),
    spec("run", "run champion|exp/ID|BUILD|BENCH --scenario S [--fixture F] [--reps N] [--reference S2] [--set k=v] [--knobs k=v] [runner flags]",
         valued: ["scenario", "fixture", "reps", "reference", "set", "knobs", "exe"], positional: 1...1, runner: true),
    spec("baseline", "baseline SCENARIO --bench PATH|--build HASH [--fixture F] [--reps N] [--reference S2] [runner flags]",
         valued: ["bench", "build", "fixture", "reps", "reference", "exe"], positional: 1...1, runner: true),
    spec("suggest", "suggest [champion|exp/ID|RESULT.json] [--top N] [--json]", valued: ["top"], positional: 0...1),
    spec("causes", "causes RESULT.json [--json]", positional: 1...1),
    spec("profile", "profile champion|exp/ID [--template time|hitches|swiftui] [--scenario S] [--fixture F] [--keep-trace] [runner flags]",
         valued: ["template", "scenario", "fixture"], flags: ["keep-trace"], positional: 1...1, runner: true),
    spec("diff", "diff A B [--exp ID] [--allow-stale]", valued: ["exp"], flags: ["allow-stale"], positional: 2...2),
    spec("trace register", "trace register TRACE --build HASH", valued: ["build"], positional: 1...1),
    spec("ledger", "ledger [--json]"),
    spec("session start", "session start [--note \"…\"]", valued: ["note"], flags: ["owner"]),
    spec("queue", "queue list [--all] [--json]", flags: ["all"]),
    spec("queue add", "queue add ID [--stage auto|screen|full] [--runner R] [--note \"…\"]", valued: ["stage", "runner", "note"], flags: ["force"], positional: 1...1),
    spec("queue list", "queue list [--all] [--json]", flags: ["all"]),
    spec("queue remove", "queue remove QID", positional: 1...1),
    spec("queue run", "queue run --runner R [--until HH:MM] [--idle S] [runner flags]", valued: ["until"], flags: ["force"], runner: true),
    spec("runner check", "runner check R [runner flags]", positional: 1...1, runner: true),
    spec("runner clean", "runner clean R [runner flags]", positional: 1...1, runner: true),
    spec("gestures", "gestures list [FILE…] [--dir DIR]… [--bench PATH] [--json]", valued: ["dir", "bench", "exe"], ownHelp: true),
    spec("gestures list", "gestures list [FILE…] [--dir DIR]… [--bench PATH] [--json]", valued: ["dir", "bench", "exe"], positional: 0...Int.max, ownHelp: true),
    spec("mcp", "mcp [--app NAME | --store DIR] [--lock DIR]", valued: ["lock"]),
    spec("sweep", "sweep SCENARIO --set NAME=4..64/4 [--set …] [--bench PATH] [--fixture F] [--reps N] [--dry-run] [--json] (perfloop sweep --help)",
         valued: ["bench", "exe", "fixture", "set", "reps", "objective", "out", "budget-min", "budget-ms", "lock", "lock-every", "order", "redo", "rep-s", "startup-s"],
         flags: ["dry-run", "fresh", "no-lock"], positional: 0...1, ownHelp: true),
    spec("sweep show", "sweep show DIR|sweep.json [--json]", positional: 1...1, ownHelp: true),
    spec("lock", "lock [--lock DIR] [--label TEXT] -- CMD [ARG…] | lock [--json]", valued: ["lock", "label"], flags: ["no-lock"], ownHelp: true),
  ]

  /// What a check decided: go on, or print this help (exit 0).
  public enum Outcome: Equatable { case ok, help(String) }

  /// Checks `argv` (the arguments after `perfloop`) against its subcommand's spec. Throws `PLError.usage` naming the
  /// first argument it doesn't take, with the usage line. An unknown subcommand is left to the dispatcher (its own
  /// "unknown command" message).
  @discardableResult
  public static func check(_ argv: [String]) throws -> Outcome {
    // `lock … -- CMD`: CMD's arguments are CMD's.
    var argv = argv
    let words = commandWords(argv)
    if words.first == "lock", let cut = argv.firstIndex(of: "--") { argv = Array(argv[..<cut]) }
    guard let s = spec(for: words) else { return .ok }
    let name = "perfloop \(s.command)"
    var positional = 0, skipped = 0, i = 0
    let cmdCount = s.command.split(separator: " ").count
    while i < argv.count {
      let a = argv[i]
      if a.hasPrefix("--") {
        let k = String(a.dropFirst(2))
        if k.contains(where: \.isWhitespace) {
          let parts = a.split(whereSeparator: \.isWhitespace).map(String.init)
          throw PLError.usage("unknown argument '\(a)' for \(name): a flag and its value are two arguments ('\(parts[0])' '\(parts.dropFirst().joined(separator: " "))'); "
                              + "a shell variable holding both is one argument in zsh (use an array, or write them out)\n\(s.usage)")
        }
        if k.contains("=") {
          let f = String(k.prefix { $0 != "=" })
          throw PLError.usage("unknown argument '\(a)' for \(name): write '--\(f)' and its value as two arguments\n\(s.usage)")
        }
        if s.valued.contains(k) {
          guard i + 1 < argv.count, !argv[i + 1].hasPrefix("--") else { throw PLError.usage("\(a) needs a value (\(name))\n\(s.usage)") }
          i += 2; continue
        }
        guard s.flags.contains(k) else { throw PLError.usage("unknown argument '\(a)' for \(name)\n\(s.usage)") }
        // `--more` takes a count when the next word is a number (the CLI's Args.countValued).
        i += k == "more" && i + 1 < argv.count && Int(argv[i + 1]) != nil ? 2 : 1; continue
      }
      if skipped < cmdCount { skipped += 1; i += 1; continue }
      positional += 1
      if positional > s.positional.upperBound { throw PLError.usage("unexpected argument '\(a)' for \(name)\n\(s.usage)") }
      i += 1
    }
    if argv.contains("--help") && !s.ownHelp { return .help(s.usage) }
    return .ok
  }

  /// The subcommand a command line names: its two-word form (`exp new`) when there is one, else the first word.
  public static func spec(for words: [String]) -> Spec? {
    if words.count >= 2, let s = specs.first(where: { $0.command == "\(words[0]) \(words[1])" }) { return s }
    return words.first.flatMap { w in specs.first { $0.command == w } }
  }

  /// The positional words of a command line, skipping every flag any subcommand takes a value for (their values
  /// aren't words), so `--store DIR exp new …` still names `exp new`.
  static func commandWords(_ argv: [String]) -> [String] {
    let valued = specs.reduce(into: Set<String>()) { $0.formUnion($1.valued) }
    var out: [String] = [], i = 0
    while i < argv.count, out.count < 2 {
      let a = argv[i]
      if a == "--" { break }
      if a.hasPrefix("--") { i += valued.contains(String(a.dropFirst(2))) ? 2 : 1; continue }
      out.append(a); i += 1
    }
    return out
  }
}

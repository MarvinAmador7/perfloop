import Foundation
import PerfLoopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The CLI's gate on the owner's flags (OwnerFlags in PerfLoopKit), as the MCP server's is to offer none: a flag is
/// honoured only when the shell shows it is the owner's, by `PERFLOOP_OWNER=1` in its environment or a yes typed at a
/// terminal (stdin and stderr both a TTY). Anything else is refused (exit 6) with what the agent should do instead. The
/// owner's commands (`champion set`, `exp replay --go`) pass the same gate (`check(command:)`).
///
/// That is the whole mechanism, by the owner's choice: a typed yes or the variable, no Touch ID, password or key. An
/// agent's shell usually has no terminal, so the prompt never reaches it; it can set an environment variable, so the
/// variable is a speed bump and a record, not security. The record (OwnerFlagUse) is what makes a use visible.
public struct OwnerGate {
  public var env: [String: String]
  /// stdin and stderr are a terminal: someone can answer the prompt.
  public var terminal: Bool
  /// Shows the question and returns the line typed (nil at end of input).
  public var ask: (String) -> String?

  public init(env: [String: String] = ProcessInfo.processInfo.environment, terminal: Bool = OwnerGate.isTerminal(),
              ask: @escaping (String) -> String? = { q in FileHandle.standardError.write(Data(q.utf8)); return readLine() }) {
    self.env = env; self.terminal = terminal; self.ask = ask
  }

  public static func isTerminal() -> Bool { isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0 }

  /// nil when no owner flag was passed; the authorisation when the owner's; otherwise a refusal.
  public func check(flags: [String], command: String) throws -> OwnerAuth? {
    let fs = OwnerFlags.all.filter(flags.contains)
    guard !fs.isEmpty else { return nil }
    let named = fs.map { "--" + $0 }
    let what = fs.count == 1 ? "\(named[0]) is an owner flag: \(OwnerFlags.effect(fs[0], command: command))"
                             : "\(named.joined(separator: " and ")) are owner flags (" + fs.map { "--\($0): \(OwnerFlags.effect($0, command: command))" }.joined(separator: "; ") + ")"
    return try confirm(named, what: what, dont: fs.count == 1 ? "don't pass it" : "don't pass them", command: command,
                       instead: Self.agentPaths(fs, command: command))
  }

  /// An owner command (`champion set`, `exp replay` with `--go`): the authorisation when the owner's, else a refusal.
  public func check(command: String) throws -> OwnerAuth {
    try confirm([command], what: "`perfloop \(command)` is the owner's: \(OwnerFlags.effect(command, command: command))", dont: "don't run it", command: command,
                instead: Self.agentPaths([command], command: command))
  }

  /// A command that is the owner's only in one case (`champion merged` on a dirty champion): `why` says which.
  public func check(command: String, because why: String) throws -> OwnerAuth {
    try confirm([command], what: why, dont: "don't run it again", command: command, instead: Self.agentPaths([command], command: command))
  }

  func confirm(_ named: [String], what: String, dont: String, command: String, instead: String) throws -> OwnerAuth {
    if env["PERFLOOP_OWNER"] == "1" { return OwnerAuth(flags: named, via: "env", command: command) }
    if terminal {
      let a = ask("perfloop: \(what).\nAre you the owner of this loop, at this keyboard? An agent answers no and asks the owner. "
                  + "Type yes to go on (anything else stops it; this typed yes is the only confirmation perfloop asks for): ")
      if a?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" { return OwnerAuth(flags: named, via: "tty", command: command) }
      throw PLError.refused("\(named.joined(separator: " ")) not confirmed (only a typed yes confirms): nothing ran. " + instead)
    }
    throw PLError.refused("\(what). Nothing shows the owner is running this (no PERFLOOP_OWNER=1, no terminal to type yes at), so nothing ran. "
                          + "Only the owner confirms, by typing yes when they run it at their own terminal (or with PERFLOOP_OWNER=1 on their own command line); there is no other way. "
                          + "If you are an agent, stop: \(dont), don't set PERFLOOP_OWNER, and don't look for another way around it. " + instead)
  }

  static func agentPaths(_ fs: [String], command: String) -> String {
    "Instead: " + fs.map { OwnerFlags.agentPath($0, command: command) }.joined(separator: "; and ") + "."
  }
}

extension Loop {
  /// Records that an owner flag changed what happened to `e` (the caller saves `e`), and marks the ledger lines this
  /// run writes for it.
  func ownerUsed(_ e: inout Experiment, _ flag: String, _ effect: String) {
    let a = owner
    e.used(OwnerFlagUse(flag: flag, via: a?.via ?? "library", command: a?.command ?? "library call", effect: effect, at: ownerAt))
    ownerMarked[e.id, default: []].insert(flag)
    log("exp \(e.id): owner flag \(flag) (\(OwnerAuth.viaText(a?.via ?? "library"))): \(effect)")
  }

  /// A ledger line with the owner flags this run used on its experiment, if any.
  func stamped(_ l: LedgerEntry) -> LedgerEntry {
    guard let fs = ownerMarked[l.experiment], !fs.isEmpty else { return l }
    var l = l
    l.ownerFlags = fs.sorted(); l.ownerVia = owner?.via ?? "library"
    return l
  }
}

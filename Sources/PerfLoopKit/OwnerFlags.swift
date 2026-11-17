import Foundation

/// The owner's flags (`--force`, `--owner`, `--guard-tolerance`, `--allow-dirty`): they override what judges the agent,
/// so an agent never passes them (AGENTS.md). The CLI honours one only when the shell shows it is the owner's
/// (`PERFLOOP_OWNER=1` in its environment, or a yes typed at a terminal), and every run that used one says so in
/// `experiment.json`, the ledger, the verdict, `explain` and `exp status`. That is a speed bump and a record, not
/// security: an agent's shell can set the variable too, and the record is what makes it visible in a PR.
///
/// The owner's commands (`champion set`, `exp replay --go`) pass the same gate: they pick the champion, the build every
/// later verdict is judged against, so an agent never runs them either.
public enum OwnerFlags {
  public static let all = ["force", "owner", "guard-tolerance", "allow-dirty"]
  /// Commands that are the owner's whatever their flags (OwnerGate.check(command:)).
  public static let commands = ["champion set", "exp replay"]

  /// What the flag does, for the prompt and the refusal.
  public static func effect(_ flag: String, command: String) -> String {
    switch flag {
    case "force":
      if command.hasPrefix("queue run") { return "it starts reps while someone may be using this Mac (no idle gate)" }
      if command.hasPrefix("queue") { return "it queues a full for an experiment its screen rejected" }
      return "it runs a full on an experiment its screen rejected (or one that lost)"
    case "owner": return "it acts as the owner: approves a promotion or a full that waits for the owner, clears a snapshot review"
    case "guard-tolerance": return "it changes what a correctness guard tolerates"
    case "allow-dirty": return "it promotes a build with uncommitted changes"
    case "champion set": return "it picks the champion, the build every later verdict is judged against"
    case "exp replay": return "it sets the plan's champion, the build every later verdict is judged against, and promotes the plan's builds, dirty ones too"
    default: return "it overrides what judges the agent"
    }
  }

  /// The refusal of a full (or a queued one) after a rejected screen: the agent's way on, not the owner's flag.
  public static func rejectedScreen(_ id: String) -> String {
    "exp \(id) was rejected by its screen, and a rejected screen gets no full: that is the verdict. Drop the change (reset your work branch) and try "
      + "the next idea; if you think the screen was borderline, report it to the owner with its numbers (perfloop explain exp/\(id)) and let them decide"
  }

  /// The agent's own way forward when it reached for the flag: what to do today instead.
  public static func agentPath(_ flag: String, command: String) -> String {
    switch flag {
    case "force" where command.hasPrefix("queue run"):
      return "queue the work and let `perfloop queue run --runner local --idle 120` start it once nobody is using this Mac, or use a spare Mac (--runner ssh://…)"
    case "force":
      return "a rejected screen is the verdict: drop the change (reset your work branch) and try the next idea; if you think the screen was borderline, report it to the owner with its numbers (perfloop explain exp/ID) and let them decide"
    case "owner":
      return "what waits for the owner (a needsReview, a declared behaviour change, a changed contract) is theirs to decide: report the experiment with its explain.txt and go on with the next idea"
    case "guard-tolerance":
      return "a snapshot over tolerance is the owner's to look at: report it with the PNGs and the diff its explain.txt lists"
    case "allow-dirty":
      return "commit, rebuild, and measure the build again in a new experiment"
    case "champion set":
      return "the champion moves only when one of your experiments wins and is promoted (perfloop exp promote ID); if there is no champion yet, or it looks wrong, ask the owner to set it"
    case "exp replay":
      return "print the plan (perfloop exp replay PLAN.json --dry-run) and ask the owner to run it"
    default: return "stop and ask the owner"
    }
  }
}

/// How a shell showed it was the owner's: `env` (`PERFLOOP_OWNER=1`) or `tty` (a yes typed at a terminal).
public struct OwnerAuth: Codable, Sendable, Equatable {
  /// The owner flags as passed: `--force`, `--owner`, …; or the owner command (`champion set`).
  public var flags: [String]
  public var via: String
  /// The command they came with (`exp full`, `queue add`, …).
  public var command: String
  public init(flags: [String], via: String, command: String) { self.flags = flags; self.via = via; self.command = command }

  public static func viaText(_ via: String) -> String {
    switch via {
    case "env": return "PERFLOOP_OWNER=1"
    case "tty": return "confirmed at a terminal"
    default: return via
    }
  }
}

/// One use of an owner flag that changed what happened to an experiment (`experiment.json` → `ownerFlags`), or of an
/// owner command (`champion set`: on the baseline experiment and `champion.json` → `setBy`).
public struct OwnerFlagUse: Codable, Sendable, Equatable {
  /// `--force`, `--owner`, `--guard-tolerance` or `--allow-dirty`; `champion set` for the command.
  public var flag: String
  /// env | tty (OwnerAuth), or `library` when a caller of PerfLoopRunner set it without the CLI's gate.
  public var via: String
  public var command: String
  /// What it changed: "ran the full over a rejected screen", ….
  public var effect: String
  public var at: String
  public init(flag: String, via: String, command: String, effect: String, at: String = Clock.now()) {
    self.flag = flag; self.via = via; self.command = command; self.effect = effect; self.at = at
  }

  /// One line for the verdict, `explain`, `exp status`.
  public var line: String { "\(flag) (\(OwnerAuth.viaText(via)), \(command), \(at)): \(effect)" }
}

import Foundation
import PerfLoopKit

/// `perfloop lock -- CMD`: any command, held inside the window lock (WindowLock). For what opens a window outside
/// perfloop's own verbs: an adapter's `ab` or `run` called directly, a script that drives the app. CMD gets this
/// process's stdin, stdout and stderr, and `PERFLOOP_LOCK_HELD`, so a perfloop or PerfLoopHost bench inside it doesn't
/// wait for the lock its parent holds.
public enum LockCommand {
  static let mutex = NSLock()
  static var child: Process?

  /// Waits for the lock, runs `cmd` (found on PATH), gives the lock back; returns CMD's exit status (128 + N when signal
  /// N ended it).
  public static func run(_ cmd: [String], path: String, label: String?, poll: Double = 2, log: @escaping (String) -> Void) throws -> Int32 {
    let lock: WindowLock
    do { lock = try WindowLock.acquire(path, label: label, poll: poll, log: log) }
    catch let f as WindowLock.Failure { throw PLError.harness(f.description) }
    defer { lock.release() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = cmd
    p.environment = ProcessInfo.processInfo.environment.merging(WindowLock.childEnv) { _, b in b }
    do { try p.run() } catch { throw PLError.harness("couldn't start \(cmd[0]): \(error)") }
    mutex.lock(); child = p; mutex.unlock()
    p.waitUntilExit()
    mutex.lock(); child = nil; mutex.unlock()
    return p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
  }

  /// Kills the command and its descendants (a signal handler's act, before the lock is released).
  public static func killChild() {
    let got = mutex.try()
    let p = child
    if got { mutex.unlock() }
    if let p, p.isRunning { ProcessTree.kill(p.processIdentifier, grace: 2) }
  }
}

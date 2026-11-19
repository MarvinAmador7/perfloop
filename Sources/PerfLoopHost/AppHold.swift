#if os(macOS)
import AppKit
import ObjectiveC

/// Keeps the app alive while a window verb runs, until it has written its result and exits with the run's code.
///
/// A bench inside the app (`bench.attach()` from a SwiftUI `App`, or `host: .app` under `bench.main()`) runs under the
/// app's own delegate, and that delegate decides when the app quits: a SwiftUI app with one `Window` scene quits when
/// its last window closes, which is what `run.close` does to `run.open`'s window at the end of a rep. The process then
/// exited 0 before the result was written, and perfloop could only say "the run exited 0 without a result". While held,
/// the delegate's `applicationShouldTerminateAfterLastWindowClosed:` answers false and `applicationShouldTerminate:`
/// cancels (whatever the app's own answers are), and each request is remembered for the result's notes; the verb ends
/// the process itself (`exit` with the run's code) once the result is out. The two methods are replaced on the
/// delegate's own class (added when it has none, the delegate set again so AppKit asks it), and call the app's own
/// implementation once nothing is held: this is bench code, never in the app a user runs.
@MainActor
enum AppHold {
  /// A window verb is running: the app may not quit.
  static var holding = false
  /// What asked the app to quit while held, once each.
  static var asked: [String] = []
  /// Classes whose two methods are replaced already.
  static var patched: Set<ObjectIdentifier> = []
  /// The delegate an app without one gets for the hold (NSApp.delegate is weak).
  static var own: HoldDelegate?
  /// Said once when the app quits anyway (something called `exit`, or a delegate the hold couldn't reach).
  static var quitObserver: NSObjectProtocol?

  /// Holds the app from now on, until `end`. `say` gets each request to quit (stderr, for the runner's log).
  static func begin(say: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
    holding = true; asked = []; Self.say = say
    let app = NSApplication.shared
    if app.delegate == nil { let d = HoldDelegate(); own = d; app.delegate = d }
    if let d = app.delegate as? NSObject { patch(d, app: app) }
    if quitObserver == nil {
      quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        MainActor.assumeIsolated {
          guard holding else { return }
          Self.say("the app is quitting (NSApplication terminate) before the run wrote its result: perfloop will see no result for this run")
        }
      }
    }
  }

  static func end() { holding = false }

  static var say: (String) -> Void = { _ in }

  /// Remembers a request to quit while held, and says it once.
  static func refuse(_ what: String) {
    guard !asked.contains(what) else { return }
    asked.append(what)
    say("the app asked to quit during the run (\(what)): kept running until the result is written")
  }

  /// The note the result carries when the app asked to quit while held.
  static var note: String? {
    asked.isEmpty ? nil : "the app asked to quit during the run (\(asked.joined(separator: "; "))): PerfLoopHost kept it running until the result was written; "
      + "outside the bench it would have quit there"
  }

  static let lastWindow = NSSelectorFromString("applicationShouldTerminateAfterLastWindowClosed:")
  static let shouldTerminate = NSSelectorFromString("applicationShouldTerminate:")

  /// Replaces (or adds) the two methods on the delegate's class.
  static func patch(_ delegate: NSObject, app: NSApplication) {
    let cls: AnyClass = object_getClass(delegate) ?? type(of: delegate)
    guard !patched.contains(ObjectIdentifier(cls)) else { return }
    patched.insert(ObjectIdentifier(cls))
    var added = false
    let lastWindow = Self.lastWindow, shouldTerminate = Self.shouldTerminate

    typealias LastFn = @convention(c) (AnyObject, Selector, NSApplication) -> Bool
    let lastOriginal = class_getInstanceMethod(cls, lastWindow).map(method_getImplementation)
    let last: @convention(block) (AnyObject, NSApplication) -> Bool = { obj, app in
      let theirs = lastOriginal.map { unsafeBitCast($0, to: LastFn.self)(obj, lastWindow, app) } ?? false
      guard theirs else { return false }
      return MainActor.assumeIsolated {
        guard holding else { return true }
        refuse("its last window closed, and its delegate quits then")
        return false
      }
    }
    added = install(cls, lastWindow, imp_implementationWithBlock(last), types: "c@:@") || added

    typealias TermFn = @convention(c) (AnyObject, Selector, NSApplication) -> UInt
    let termOriginal = class_getInstanceMethod(cls, shouldTerminate).map(method_getImplementation)
    let term: @convention(block) (AnyObject, NSApplication) -> UInt = { obj, app in
      let held = MainActor.assumeIsolated { () -> Bool in
        guard holding else { return false }
        refuse("NSApplication terminate")
        return true
      }
      if held { return NSApplication.TerminateReply.terminateCancel.rawValue }
      return termOriginal.map { unsafeBitCast($0, to: TermFn.self)(obj, shouldTerminate, app) } ?? NSApplication.TerminateReply.terminateNow.rawValue
    }
    added = install(cls, shouldTerminate, imp_implementationWithBlock(term), types: "Q@:@") || added
    // AppKit may have read what the delegate answers when it was set: set it again so it asks the added methods.
    if added { app.delegate = nil; app.delegate = delegate as? NSApplicationDelegate }
  }

  /// The class's own method replaced, or added (true) when only a superclass has one or none does.
  static func install(_ cls: AnyClass, _ sel: Selector, _ imp: IMP, types: String) -> Bool {
    let enc = protocolTypes(sel) ?? types
    if class_addMethod(cls, sel, imp, enc) { return true }
    if let m = class_getInstanceMethod(cls, sel) { method_setImplementation(m, imp) }
    return false
  }

  /// The method's type encoding as NSApplicationDelegate declares it (BOOL is `c` or `B` by architecture).
  static func protocolTypes(_ sel: Selector) -> String? {
    guard let p = NSProtocolFromString("NSApplicationDelegate") else { return nil }
    let d = protocol_getMethodDescription(p, sel, false, true)
    return d.types.map { String(cString: $0) }
  }
}

/// The hold's delegate for an app that has none: it answers like AppKit's default (stay up when the last window closes;
/// quit when asked) until the hold refuses.
final class HoldDelegate: NSObject, NSApplicationDelegate {}
#endif

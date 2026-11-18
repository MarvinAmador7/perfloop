#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ObjectiveC
import PerfLoopKit

// Real input, in-process (VERIFICATION.md §1 claim 3; the study's F12, F13): keys, shortcuts, text and clicks made as
// the window server would make them and put on this app's own event queue with `NSApp.postEvent`, so they take the
// path a hand's do: `NSApp.currentEvent`, the main menu's key equivalents, the window's, the responder chain, field
// editors, gesture recognizers. Nothing goes to the system: no CGEvent is posted to the session, so no other app (and
// not the owner's Mac) ever sees one.
//
// Why not `sendEvent`: `NSApp.sendEvent` skips the queue, so `currentEvent` isn't the event (a palette opened that way
// looked pointer-opened). Why not `NSEvent.keyEvent(…)`: AppKit matches a hand-made key event's shortcut on its
// characters alone, so ⇧⌘D with `charactersIgnoringModifiers` "d" fires ⌘D's item. A key event made from a CGEvent
// (never posted) carries the virtual key and the modifiers, and AppKit derives its characters from the keyboard layout
// and matches ⇧⌘D to ⇧⌘D, as for a hand.
//
// Every input step records what happened: the menu item that fired (or that none did, and what took the key instead),
// which view a click hit and what took the mouse-down, and the focus before and after (Run.step). With `--pictures
// DIR` the window before and after a step that changed what is visible, and where it changed.

// MARK: the keyboard layout

/// The current keyboard layout: which characters a virtual key types, with ⇧ and ⌥.
@MainActor public protocol KeyLayout {
  var name: String { get }
  func character(_ keyCode: Int, shift: Bool, option: Bool) -> String?
}

/// The layout this process types with (TIS's current keyboard layout, UCKeyTranslate).
@MainActor public final class SystemKeyLayout: KeyLayout {
  public let name: String
  let data: CFData?
  public init() {
    let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    func prop(_ k: CFString) -> UnsafeMutableRawPointer? { src.flatMap { TISGetInputSourceProperty($0, k) } }
    name = prop(kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "unknown"
    data = prop(kTISPropertyUnicodeKeyLayoutData).map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
  }
  public func character(_ keyCode: Int, shift: Bool, option: Bool) -> String? {
    guard let d = data, let p = CFDataGetBytePtr(d) else { return nil }
    var dead: UInt32 = 0, len = 0
    var chars = [UniChar](repeating: 0, count: 4)
    let mods = UInt32((shift ? shiftKey : 0) | (option ? optionKey : 0)) >> 8 & 0xFF
    let st = p.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
      UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
    }
    guard st == noErr, len > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: len)
  }
}

/// A key to press: the virtual key and the modifiers (Carbon's kVK_* codes, the same on every layout).
public struct KeyPress: Sendable, Equatable {
  public var keyCode: Int
  public var command = false, shift = false, option = false, control = false
  /// A key that isn't a character (arrows, F-keys, ⌦…): AppKit's events carry the function (and arrows the keypad) flag.
  public var function = false
  public var arrow = false
  public init(keyCode: Int, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, function: Bool = false, arrow: Bool = false) {
    self.keyCode = keyCode; self.command = command; self.shift = shift; self.option = option; self.control = control; self.function = function; self.arrow = arrow
  }
  var flags: CGEventFlags {
    var f: CGEventFlags = []
    if command { f.insert(.maskCommand) }; if shift { f.insert(.maskShift) }; if option { f.insert(.maskAlternate) }; if control { f.insert(.maskControl) }
    if function || arrow { f.insert(.maskSecondaryFn) }; if arrow { f.insert(.maskNumericPad) }
    return f
  }
  var modifierFlags: NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if command { f.insert(.command) }; if shift { f.insert(.shift) }; if option { f.insert(.option) }; if control { f.insert(.control) }
    return f
  }
}

/// Which key types a character on a layout, and which key a shortcut means there: ⌘Z is the key that types "z" (where
/// a German layout has Y), ⌘? is ⇧ and the key that types "?" with it.
@MainActor public struct KeyMap {
  public let layout: String
  /// Character → the key and the modifiers that type it; the fewest modifiers win.
  var keys: [String: (code: Int, shift: Bool, option: Bool)] = [:]
  /// Each key's character without modifiers.
  var base: [Int: String] = [:]

  public init(_ l: KeyLayout) {
    layout = l.name
    for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
      for code in 0..<128 where Shortcut.named.values.contains(code) == false {
        guard let c = l.character(code, shift: shift, option: option), c.count == 1, let s = c.unicodeScalars.first, s.value >= 0x20, s.value != 0x7f else { continue }
        if keys[c] == nil { keys[c] = (code, shift, option) }
        if !shift && !option { base[code] = c }
      }
    }
  }

  /// The key and modifiers for a shortcut, or why there is none on this layout.
  public func press(_ s: Shortcut) -> Result<KeyPress, ShortcutError> {
    if let code = Shortcut.named[s.key] {
      let arrow = (123...126).contains(code), fn = arrow || [117, 115, 119, 116, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(code)
      return .success(KeyPress(keyCode: code, command: s.command, shift: s.shift, option: s.option, control: s.control, function: fn, arrow: arrow))
    }
    guard let k = keys[s.key] ?? keys[s.key.lowercased()] else {
      return .failure(ShortcutError("no key types '\(s.key)' on the keyboard layout \(layout)"))
    }
    // ⌥ is part of the key here only when the character needs it (⌥L for "@" on a German layout).
    return .success(KeyPress(keyCode: k.code, command: s.command, shift: s.shift || k.shift, option: s.option || k.option, control: s.control))
  }

  /// The key for one typed character, nil when the layout has none (it is then typed as text).
  public func stroke(_ c: Character) -> KeyPress? {
    switch c {
    case "\n", "\r": return KeyPress(keyCode: 36)
    case "\t": return KeyPress(keyCode: 48)
    default: break
    }
    guard let k = keys[String(c)] else { return nil }
    return KeyPress(keyCode: k.code, shift: k.shift, option: k.option)
  }
}

// MARK: making events

enum InputEvents {
  /// The CGEvent field that carries the window an event is for (kCGMouseEventWindowUnderMousePointer): NSEvent takes
  /// its `windowNumber` from it, for key events too.
  static let windowField = CGEventField(rawValue: 51)!
  static let markerSubtype: Int16 = 0x7e1

  /// The modifier keys' virtual keys and flags, in the order a hand presses them.
  static let modifierKeys: [(code: CGKeyCode, flag: CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]

  /// The events a hand makes: each modifier down (`flagsChanged`), the key down and up, the modifiers up again, made by
  /// the system from the virtual keys (characters from the current layout), for `window`. The modifiers' own events
  /// matter: AppKit keeps the modifier state they set, and without the release a later ⌘D still reads as ⇧⌘D.
  /// `text`: characters to carry instead (one the layout has no key for, as an input method would insert it).
  static func key(_ p: KeyPress, window: NSWindow?, text: String? = nil) -> [NSEvent] {
    let src = CGEventSource(stateID: .privateState)
    func event(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, text: String? = nil) -> NSEvent? {
      guard let cg = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return nil }
      cg.flags = flags
      if let t = text { let u = Array(t.utf16); cg.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
      if let w = window { cg.setIntegerValueField(windowField, value: Int64(w.windowNumber)) }
      return NSEvent(cgEvent: cg)
    }
    let mods = modifierKeys.filter { p.flags.contains($0.flag) }
    var held: CGEventFlags = [], out: [NSEvent?] = []
    for m in mods { held.insert(m.flag); out.append(event(m.code, down: true, flags: held)) }
    out.append(event(CGKeyCode(p.keyCode), down: true, flags: p.flags, text: text))
    out.append(event(CGKeyCode(p.keyCode), down: false, flags: p.flags, text: text))
    for m in mods.reversed() { held.remove(m.flag); out.append(event(m.code, down: false, flags: held)) }
    return out.compactMap { $0 }
  }

  /// A click (or `count` clicks) at `point` in `window`'s coordinates.
  static func click(at point: CGPoint, window: NSWindow, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> [NSEvent] {
    (1...max(1, count)).flatMap { n in
      [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap {
        NSEvent.mouseEvent(with: $0, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: n, clickCount: n, pressure: $0 == .leftMouseDown ? 1 : 0)
      }
    }
  }

  /// The event posted after the input: when the queue reaches it, everything before it has been handled.
  static func marker(_ id: Int) -> NSEvent? {
    NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: markerSubtype, data1: id, data2: 0)
  }
}

// MARK: what happened to the events

/// The responders that passed a mouse-down or key-down on (AppKit's default `mouseDown`/`keyDown` sends it to the next
/// responder), and what the windows' key-equivalent pass returned. The first responder of a chain that didn't pass the
/// event on is the one that took it. Installed once, on the first input step; it records only while a step's input is
/// in flight.
final class InputTrace: @unchecked Sendable {
  static let shared = InputTrace()
  var recording = false
  var mousePassed: [ObjectIdentifier] = []
  var keyPassed: [ObjectIdentifier] = []
  var keyEquivalent: [(window: ObjectIdentifier, taken: Bool)] = []
  private var installed = false

  func reset() { mousePassed = []; keyPassed = []; keyEquivalent = [] }

  func install() {
    guard !installed else { return }
    installed = true
    passOn(#selector(NSResponder.mouseDown(with:))) { $0.mousePassed.append($1) }
    passOn(#selector(NSResponder.keyDown(with:))) { $0.keyPassed.append($1) }
    let sel = #selector(NSWindow.performKeyEquivalent(with:))
    guard let m = class_getInstanceMethod(NSWindow.self, sel) else { return }
    typealias F = @convention(c) (AnyObject, Selector, NSEvent) -> Bool
    let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
    let block: @convention(block) (AnyObject, NSEvent) -> Bool = { [unowned self] o, e in
      let r = orig(o, sel, e)
      if recording { keyEquivalent.append((ObjectIdentifier(o), r)) }
      return r
    }
    method_setImplementation(m, imp_implementationWithBlock(block))
  }

  /// NSResponder's own implementation (what a responder that doesn't take the event ends up in), wrapped.
  private func passOn(_ sel: Selector, _ note: @escaping (InputTrace, ObjectIdentifier) -> Void) {
    guard let m = class_getInstanceMethod(NSResponder.self, sel) else { return }
    typealias F = @convention(c) (AnyObject, Selector, NSEvent) -> Void
    let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
    let block: @convention(block) (AnyObject, NSEvent) -> Void = { [unowned self] o, e in
      if recording { note(self, ObjectIdentifier(o)) }
      orig(o, sel, e)
    }
    method_setImplementation(m, imp_implementationWithBlock(block))
  }
}

/// The end of a responder chain while input is in flight: an event that reaches it was taken by nobody. It passes it on
/// (to nothing: AppKit beeps for a key, as it would have).
final class ChainEnd: NSResponder {
  var keys = 0, mice = 0
  override func keyDown(with e: NSEvent) { keys += 1; super.keyDown(with: e) }
  override func mouseDown(with e: NSEvent) { mice += 1; super.mouseDown(with: e) }
}

/// One input step's watch: the menu's actions, the trace, the chain's end, gesture recognizers, and the marker that
/// says the events were handled.
@MainActor final class InputProbe {
  static var serial = 0
  let id: Int
  private(set) var delivered = false
  var fired: [(item: NSMenuItem, target: AnyObject?)] = []
  let end = ChainEnd()
  private weak var endOwner: NSResponder?
  private var monitor: Any?
  private var observer: NSObjectProtocol?
  private var recognizers: [(NSGestureRecognizer, NSKeyValueObservation)] = []
  var recognized: [NSGestureRecognizer] = []

  init() { Self.serial += 1; id = Self.serial }

  /// Starts watching; `chainFrom`'s responder chain gets the end marker.
  func arm(chainFrom start: NSResponder?, recognizersOf hit: NSView? = nil) {
    InputTrace.shared.install()
    InputTrace.shared.reset(); InputTrace.shared.recording = true
    observer = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { [weak self] n in
      MainActor.assumeIsolated {
        guard let self, let item = n.userInfo?["MenuItem"] as? NSMenuItem else { return }
        let target: AnyObject? = item.action.flatMap { NSApp.target(forAction: $0, to: item.target, from: item) as AnyObject? }
        self.fired.append((item, target))
      }
    }
    let id = id
    monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] e in
      guard e.subtype.rawValue == InputEvents.markerSubtype, e.data1 == id else { return e }
      MainActor.assumeIsolated { self?.delivered = true }
      return nil
    }
    if let s = start {
      var r: NSResponder = s, n = 0
      while let next = r.nextResponder, n < 64 { r = next; n += 1 }
      if r !== end { r.nextResponder = end; endOwner = r }
    }
    var v = hit
    while let x = v {
      for g in x.gestureRecognizers where g.isEnabled {
        let o = g.observe(\.state, options: [.new]) { [weak self] g, _ in
          let s = g.state
          MainActor.assumeIsolated { if [.began, .ended].contains(s), self?.recognized.contains(where: { $0 === g }) == false { self?.recognized.append(g) } }
        }
        recognizers.append((g, o))
      }
      v = x.superview
    }
  }

  func post(_ events: [NSEvent]) {
    for e in events { NSApp.postEvent(e, atStart: false) }
    if let m = InputEvents.marker(id) { NSApp.postEvent(m, atStart: false) }
  }

  /// Waits up to `timeoutMs` for the marker. Outside NSApp's run loop (a test) it dispatches the queue itself, as the
  /// run loop would.
  func waitDelivered(timeoutMs: Double) async {
    let until = Date().addingTimeInterval(timeoutMs / 1000)
    while !delivered, Date() < until {
      if !NSApp.isRunning {
        while !delivered, let e = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
      }
      if !delivered { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
  }

  func disarm() {
    InputTrace.shared.recording = false
    if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    if let o = endOwner, o.nextResponder === end { o.nextResponder = nil }
    endOwner = nil
    recognizers.forEach { $0.1.invalidate() }; recognizers = []
  }
}

// MARK: focus

/// Where to expect the keyboard after a step (`expectFocus:`, `run.expectFocus`): a view (or a view inside it), an
/// identifier (the focused view's, or an ancestor's: "focus is in the sidebar"), a class, a label (a field's
/// placeholder or title), nothing focused, or no change.
public struct FocusTarget: CustomStringConvertible {
  enum Kind { case view(NSView, String), identifier(String), className(String), label(String), nothing, unchanged }
  let kind: Kind
  @MainActor public static func view(_ v: NSView) -> FocusTarget { FocusTarget(kind: .view(v, Focus.ref(v).text)) }
  public static func identifier(_ s: String) -> FocusTarget { FocusTarget(kind: .identifier(s)) }
  public static func className(_ s: String) -> FocusTarget { FocusTarget(kind: .className(s)) }
  public static func label(_ s: String) -> FocusTarget { FocusTarget(kind: .label(s)) }
  /// No view has the keyboard (the window itself is first responder, or no window is key).
  public static let nothing = FocusTarget(kind: .nothing)
  public static let unchanged = FocusTarget(kind: .unchanged)

  public var description: String {
    switch kind {
    case .view(_, let text): text
    case .identifier(let s): "#\(s)"
    case .className(let s): s
    case .label(let s): "\"\(s)\""
    case .nothing: "nothing"
    case .unchanged: "no change"
    }
  }

  /// Whether `after` (with `view`, the focused view itself) is this target.
  @MainActor func matches(_ after: FocusRecord, before: FocusRecord, view: NSView?) -> Bool {
    let f = after.focused, fr = after.firstResponder
    switch kind {
    case .view(let v, _): return view.map { $0 === v || $0.isDescendant(of: v) } ?? false
    case .identifier(let s): return f?.identifier == s || fr?.identifier == s || (after.inside ?? []).contains(s)
    case .className(let s):
      func m(_ r: ResponderRef?) -> Bool { r.map { $0.class == s || $0.class.hasPrefix(s + "<") } ?? false }
      return m(f) || m(fr)
    case .label(let s): return f?.label == s || fr?.label == s
    case .nothing: return f == nil
    case .unchanged: return after.sameTarget(before)
    }
  }
}

@MainActor enum Focus {
  /// The focus now, with `bench` (the scenario's window) naming the windows' roles. `key`: the key window (AppKit's).
  static func record(bench: NSWindow?) -> FocusRecord { record(bench: bench, key: NSApp.keyWindow) }

  static func record(bench: NSWindow?, key: NSWindow?) -> FocusRecord {
    var r = FocusRecord(keyWindow: key.map { window($0, bench: bench) }, mainWindow: NSApp.mainWindow.map { window($0, bench: bench) })
    guard let w = key, let fr = w.firstResponder, !(fr is NSWindow) else { return r }
    if let tv = fr as? NSTextView, tv.isFieldEditor {
      r.firstResponder = ResponderRef(class: name(tv)); r.fieldEditor = true
      if let edited = tv.delegate as? NSView { r.editing = ref(edited) }
    } else { r.firstResponder = ref(fr) }
    if let v = view(w) {
      var ids: [String] = [], p = v.superview
      while let x = p, ids.count < 8 { if let i = identifier(x) { ids.append(i) }; p = x.superview }
      r.inside = ids.isEmpty ? nil : ids
    }
    return r
  }

  /// The view that has the keyboard in `window`: the edited field, else the first responder.
  static func view(_ window: NSWindow?) -> NSView? {
    guard let fr = window?.firstResponder else { return nil }
    if let tv = fr as? NSTextView, tv.isFieldEditor, let v = tv.delegate as? NSView { return v }
    return fr as? NSView
  }

  static func window(_ w: NSWindow, bench: NSWindow?) -> WindowRef {
    let role = w === bench ? "bench" : bench.map { WindowState.owns($0, key: w, parent: { $0.parent ?? $0.sheetParent }) } == true ? "child" : "other"
    return WindowRef(title: w.title, class: name(w), role: role)
  }

  /// A field editor as the field it edits (`NSTextField #filter "Filter" (field editor)`), anything else as itself.
  static func refThroughEditor(_ r: NSResponder) -> ResponderRef {
    guard let tv = r as? NSTextView, tv.isFieldEditor, let v = tv.delegate as? NSView else { return ref(r) }
    var x = ref(v); x.class += " (field editor)"
    return x
  }

  static func ref(_ r: NSResponder) -> ResponderRef {
    guard let v = r as? NSView else { return ResponderRef(class: name(r)) }
    var label: String?
    if let t = v as? NSTextField { label = t.placeholderString ?? t.placeholderAttributedString?.string ?? (t.isEditable ? nil : t.stringValue) }
    else if let b = v as? NSButton { label = b.title }
    if label?.isEmpty != false, let a = v.accessibilityLabel(), !a.isEmpty { label = a }
    return ResponderRef(class: name(v), identifier: identifier(v), label: label.map { $0.count > 60 ? String($0.prefix(57)) + "…" : $0 })
  }

  static func identifier(_ v: NSView) -> String? {
    if let i = v.identifier?.rawValue, !i.isEmpty, !i.hasPrefix("_NS:") { return i }
    let a = v.accessibilityIdentifier()
    return a.isEmpty ? nil : a
  }

  /// The class as Swift names it, with a generic's arguments elided (`NSHostingView<…>`).
  static func name(_ o: AnyObject) -> String {
    let s = String(describing: type(of: o))
    guard let i = s.firstIndex(of: "<") else { return s }
    return s[..<i] + "<…>"
  }
}

// MARK: the scenario's API

extension Run {
  /// A named key for `run.key`.
  public enum Key: String, Sendable, CaseIterable {
    case escape, `return`, enter, tab, space, delete, forwardDelete, up, down, left, right, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
  }

  /// One measured step: `shortcut` (`"⌘K"`, `"⇧⌘D"`, `"cmd+shift+d"`, `"⎋"`) pressed on the current keyboard layout and
  /// put on the app's event queue, as a hand's would be. The step records which menu item fired (and its action's
  /// target), or that none did and what took the keys instead (a view's key equivalent, a responder, or nobody), with
  /// the focus before and after. `expect`: the menu item's title (or its path, `View › Split Down`) the keys must fire,
  /// else the check `press <keys>` fails. `until` and the timing are `step`'s.
  @discardableResult
  public func press(_ shortcut: String, expect: String? = nil, expectFocus: FocusTarget? = nil, name: String? = nil, timeoutMs: Double = 5000, quietMs: Double = 100,
                    until: (() -> Bool)? = nil) async -> StepRecord {
    let label = name ?? "press \(shortcut)"
    let resolved: Result<(Shortcut, KeyPress), ShortcutError> = Shortcut.parse(shortcut).flatMap { s in keyMap.press(s).map { (s, $0) } }
    guard case .success(let (sc, kp)) = resolved else {
      if case .failure(let e) = resolved { check(label, false, "\(e)") }
      return await step(label) {}
    }
    return await keys(kind: "press", label: label, keys: sc.display, presses: [(kp, nil)], expect: expect, expectFocus: expectFocus, timeoutMs: timeoutMs, quietMs: quietMs, until: until)
  }

  /// One measured step: a named key (`.escape`, `.down`, `.return`…) with `modifiers`, recorded as `press` is.
  @discardableResult
  public func key(_ key: Key, modifiers: NSEvent.ModifierFlags = [], expectFocus: FocusTarget? = nil, name: String? = nil, timeoutMs: Double = 5000,
                  quietMs: Double = 100, until: (() -> Bool)? = nil) async -> StepRecord {
    let sc = Shortcut(key: key.rawValue, control: modifiers.contains(.control), option: modifiers.contains(.option), shift: modifiers.contains(.shift),
                      command: modifiers.contains(.command))
    let label = name ?? "key \(sc.display)"
    guard case .success(let kp) = keyMap.press(sc) else { check(label, false, "no key \(key.rawValue)"); return await step(label) {} }
    return await keys(kind: "key", label: label, keys: sc.display, presses: [(kp, nil)], expect: nil, expectFocus: expectFocus, timeoutMs: timeoutMs, quietMs: quietMs, until: until)
  }

  /// One measured step: `text` typed, a key down and up per character on the current layout (⇧ and ⌥ as the layout
  /// needs; a character no key types goes as text, as an input method inserts it), to whatever has the keyboard. One
  /// step for the whole text: type a character per step to time each key.
  @discardableResult
  public func type(_ text: String, expectFocus: FocusTarget? = nil, name: String? = nil, timeoutMs: Double = 5000, quietMs: Double = 100,
                   until: (() -> Bool)? = nil) async -> StepRecord {
    let label = name ?? "type '\(text)'"
    let presses: [(KeyPress, String?)] = text.map { c in keyMap.stroke(c).map { ($0, nil) } ?? (KeyPress(keyCode: 0), String(c)) }
    return await keys(kind: "type", label: label, keys: nil, text: text, presses: presses, expect: nil, expectFocus: expectFocus, timeoutMs: timeoutMs, quietMs: quietMs, until: until)
  }

  /// One measured step: a click on `view`, at the middle of its visible part. The step records the view AppKit
  /// hit-tested there (when it isn't `view` or inside it, something on top took the point, and the check
  /// `click <view>` fails) and what took the mouse-down: a view, a gesture recognizer, or nobody.
  @discardableResult
  public func click(_ view: NSView, count: Int = 1, modifiers: NSEvent.ModifierFlags = [], expectFocus: FocusTarget? = nil, name: String? = nil,
                    timeoutMs: Double = 5000, quietMs: Double = 100, until: (() -> Bool)? = nil) async -> StepRecord {
    let asked = Focus.ref(view)
    let label = name ?? "click \(asked.identifier.map { "#\($0)" } ?? asked.class)"
    guard let w = view.window else { check(label, false, "\(asked.text) is in no window"); return await step(label) {} }
    // The visible part (a window off every screen reports odd visible rects: keep it inside the bounds).
    let vr = view.visibleRect.intersection(view.bounds)
    let r = vr.isEmpty ? view.bounds : vr
    guard !r.isEmpty else { check(label, false, "\(asked.text) has no visible part to click"); return await step(label) {} }
    let p = view.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
    return await click(at: p, window: w, asked: asked, askedView: view, count: count, modifiers: modifiers, expectFocus: expectFocus, label: label, timeoutMs: timeoutMs,
                       quietMs: quietMs, until: until)
  }

  /// A click on the view or accessibility element (a SwiftUI view's `.accessibilityIdentifier`) with this identifier.
  @discardableResult
  public func click(identifier: String, count: Int = 1, modifiers: NSEvent.ModifierFlags = [], expectFocus: FocusTarget? = nil, name: String? = nil,
                    timeoutMs: Double = 5000, quietMs: Double = 100, until: (() -> Bool)? = nil) async -> StepRecord {
    let label = name ?? "click #\(identifier)"
    if let v = view(identifier: identifier) {
      return await click(v, count: count, modifiers: modifiers, expectFocus: expectFocus, name: label, timeoutMs: timeoutMs, quietMs: quietMs, until: until)
    }
    guard let (w, rect) = element(identifier: identifier) else {
      check(label, false, "no view or accessibility element #\(identifier) in the windows")
      return await step(label) {}
    }
    return await click(at: CGPoint(x: rect.midX, y: rect.midY), window: w, asked: ResponderRef(class: "element", identifier: identifier), askedView: nil, count: count,
                       modifiers: modifiers, expectFocus: expectFocus, label: label, timeoutMs: timeoutMs, quietMs: quietMs, until: until)
  }

  /// A click at `point` in `window`'s coordinates (the bench window's by default; AppKit's, origin bottom-left).
  @discardableResult
  public func click(at point: CGPoint, in window: NSWindow? = nil, count: Int = 1, modifiers: NSEvent.ModifierFlags = [], expectFocus: FocusTarget? = nil,
                    name: String? = nil, timeoutMs: Double = 5000, quietMs: Double = 100, until: (() -> Bool)? = nil) async -> StepRecord {
    let label = name ?? "click (\(Int(point.x)), \(Int(point.y)))"
    guard let w = window ?? self.window else { check(label, false, "no window to click in"); return await step(label) {} }
    return await click(at: point, window: w, asked: nil, askedView: nil, count: count, modifiers: modifiers, expectFocus: expectFocus, label: label, timeoutMs: timeoutMs,
                       quietMs: quietMs, until: until)
  }

  /// Checks the focus now: the check `name` (default `focus <target>`) fails, naming what has the keyboard instead.
  @discardableResult
  public func expectFocus(_ target: FocusTarget, _ name: String? = nil) -> Bool {
    let f = focus()
    let ok = focusMatches(target, f, before: f)
    check(name ?? "focus \(target)", ok, ok ? "focus: \(f.text)" : "expected \(target), focus: \(f.text)")
    return ok
  }

  /// What has the keyboard now (`FocusRecord`).
  public func focus() -> FocusRecord { Focus.record(bench: window) }

  /// Whether the focus is `target`. An identifier no view carries (SwiftUI puts `.accessibilityIdentifier` on its
  /// accessibility element, not on the AppKit view it hosts) matches when that element's frame holds the focused view.
  func focusMatches(_ target: FocusTarget, _ after: FocusRecord, before: FocusRecord) -> Bool {
    let v = Focus.view(NSApp.keyWindow)
    if target.matches(after, before: before, view: v) { return true }
    guard case .identifier(let id) = target.kind, let view = v, let w = view.window, let (ew, frame) = element(identifier: id), ew === w else { return false }
    let r = view.convert(view.bounds, to: nil)
    return frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY))
  }

  /// The view with this identifier (`NSView.identifier` or its accessibility identifier) in the bench window and the
  /// windows it owns.
  public func view(identifier: String) -> NSView? {
    func find(_ v: NSView) -> NSView? {
      if Focus.identifier(v) == identifier { return v }
      for s in v.subviews { if let f = find(s) { return f } }
      return nil
    }
    for w in benchWindows() { if let root = w.contentView?.superview ?? w.contentView, let v = find(root) { return v } }
    return nil
  }

  /// The window and the frame (window coordinates) of the accessibility element with this identifier: how a SwiftUI
  /// view's `.accessibilityIdentifier` is found, as it has no NSView of its own.
  public func element(identifier: String) -> (NSWindow, CGRect)? {
    for w in benchWindows() {
      guard let root = w.contentView else { continue }
      var queue: [Any] = [root], seen = 0
      while !queue.isEmpty, seen < 5000 {
        let x = queue.removeFirst(); seen += 1
        guard let e = x as? NSAccessibilityElementProtocol & NSObjectProtocol else { continue }
        let id = (x as? NSAccessibilityProtocol)?.accessibilityIdentifier() ?? ""
        if id == identifier, let f = (x as? NSAccessibilityProtocol)?.accessibilityFrame(), !f.isEmpty {
          return (w, w.convertFromScreen(f))
        }
        _ = e
        if let kids = (x as? NSAccessibilityProtocol)?.accessibilityChildren() { queue += kids }
      }
    }
    return nil
  }

  // MARK: the steps

  var keyMap: KeyMap {
    if let k = keyMapCache { return k }
    let k = KeyMap(SystemKeyLayout()); keyMapCache = k
    return k
  }

  /// The bench window and the visible windows it owns (panels, popovers, sheets), key window first.
  func benchWindows() -> [NSWindow] {
    guard let b = window else { return [] }
    let owned = NSApp.windows.filter { $0 !== b && $0.isVisible && WindowState.owns(b, key: $0, parent: { $0.parent ?? $0.sheetParent }) }
    return (owned + [b]).sorted { a, _ in a.isKeyWindow }
  }

  func keys(kind: String, label: String, keys: String?, text: String? = nil, presses: [(KeyPress, String?)], expect: String?, expectFocus: FocusTarget?,
            timeoutMs: Double, quietMs: Double, until: (() -> Bool)?) async -> StepRecord {
    // The window the keys are for: the key window when it is the bench window or one it owns (a palette), else the
    // bench window.
    let target = NSApp.keyWindow.flatMap { k in benchWindows().contains { $0 === k } ? k : nil } ?? window
    let events = presses.flatMap { InputEvents.key($0.0, window: target, text: $0.1) }
    let before = await picture()
    let probe = InputProbe()
    let fr = target?.firstResponder
    probe.arm(chainFrom: fr)
    var r = await step(label, timeoutMs: timeoutMs, quietMs: quietMs, until: until, expectFocus: expectFocus, input: true) { probe.post(events) }
    if !probe.delivered { await probe.waitDelivered(timeoutMs: 1000) }
    probe.disarm()
    var rec = InputRecord(kind: kind, outcome: "delivered")
    rec.keys = keys; rec.text = text; rec.layout = keyMap.layout
    if let k = presses.first?.0 { rec.keyCode = k.keyCode }
    rec.characters = events.first { $0.type == .keyDown }?.charactersIgnoringModifiers
    let asText = presses.compactMap(\.1).joined()
    if !asText.isEmpty { rec.asText = asText }
    let trace = InputTrace.shared
    if let f = probe.fired.first {
      rec.menuItem = f.item.title; rec.menuPath = Self.menuPath(f.item); rec.target = f.target.map { ResponderRef(class: Focus.name($0)) }
      let matched = expect.map { $0 == f.item.title || $0 == rec.menuPath } ?? true
      rec.outcome = matched ? "fired" : "fired-other"
    } else {
      if kind == "press" { rec.outcome = "not-fired" }
      if let fr { rec.responder = Focus.refThroughEditor(fr) }
      if probe.end.keys > 0 { rec.taken = "unhandled" }
      else if trace.keyEquivalent.contains(where: { $0.taken }) { rec.taken = "key-equivalent" }
      else if let fr {
        rec.taken = "responder"
        var x: NSResponder? = fr
        while let y = x, trace.keyPassed.contains(ObjectIdentifier(y)) { x = y.nextResponder }
        if let y = x, y !== probe.end { rec.responder = Focus.refThroughEditor(y) }
      }
      if kind == "press", let down = events.first(where: { $0.type == .keyDown }), let h = Self.holder(of: down) { rec.holder = h }
    }
    if kind == "type" { rec.count = presses.count; rec.unhandled = probe.end.keys > 0 ? probe.end.keys : nil; if rec.taken == "unhandled", probe.end.keys < presses.count { rec.taken = "responder" } }
    rec.expected = expect
    if !probe.delivered { rec.outcome = "undelivered" }
    rec.line = rec.describe()
    r.input = rec
    r.input?.pictures = await picture(after: before, step: label)
    if expect != nil { check(label, rec.outcome == "fired", rec.line) }
    else if kind == "press", rec.outcome == "undelivered" { check(label, false, rec.line) }
    if let i = r.input { r.input?.line = InputRecord.line(i, focus: r.focus) }
    replace(r)
    return r
  }

  func click(at p: CGPoint, window w: NSWindow, asked: ResponderRef?, askedView: NSView?, count: Int, modifiers: NSEvent.ModifierFlags, expectFocus: FocusTarget?,
             label: String, timeoutMs: Double, quietMs: Double, until: (() -> Bool)?) async -> StepRecord {
    let root = w.contentView?.superview ?? w.contentView
    let hitView = root.flatMap { $0.superview == nil ? $0.hitTest(p) : $0.hitTest($0.superview!.convert(p, from: nil)) }
    let wasKey = w.isKeyWindow
    let events = InputEvents.click(at: p, window: w, count: count, modifiers: modifiers)
    let before = await picture()
    let probe = InputProbe()
    probe.arm(chainFrom: hitView, recognizersOf: hitView)
    var r = await step(label, timeoutMs: timeoutMs, quietMs: quietMs, until: until, expectFocus: expectFocus, input: true) { probe.post(events) }
    if !probe.delivered { await probe.waitDelivered(timeoutMs: 1000) }
    probe.disarm()
    var rec = InputRecord(kind: "click", outcome: "hit")
    rec.point = [Stats.round(Double(p.x), 1), Stats.round(Double(p.y), 1)]
    rec.asked = asked
    var notes: [String] = []
    if let h = hitView {
      rec.hit = Focus.ref(h)
      if let a = askedView, h !== a, !h.isDescendant(of: a) { rec.outcome = "missed" }
      if let g = probe.recognized.first {
        rec.consumerKind = "gesture-recognizer"; rec.recognizer = Focus.name(g); rec.consumer = g.view.map { Focus.ref($0) }
      } else {
        var x: NSResponder? = h
        while let y = x, InputTrace.shared.mousePassed.contains(ObjectIdentifier(y)) { x = y.nextResponder }
        if let y = x, y !== probe.end, !(y is NSWindow) { rec.consumerKind = "view"; rec.consumer = Focus.ref(y) }
        else { rec.consumerKind = "nobody"; if x is NSWindow { notes.append("it reached the window, which took it (a window drag, or nothing)") } }
      }
      if rec.consumer?.class.hasPrefix("NSHostingView") == true || rec.consumer?.class.hasPrefix("_NSHostingView") == true {
        notes.append("SwiftUI decides inside its hosting view which gesture gets the click; AppKit can't say which")
      }
    } else { rec.outcome = "nothing" }
    if !wasKey { notes.append("the window wasn't key: AppKit may have used the click to make it key (a view that doesn't acceptsFirstMouse never sees it)") }
    rec.notes = notes.isEmpty ? nil : notes
    if !probe.delivered { rec.outcome = "undelivered" }
    rec.line = rec.describe()
    r.input = rec
    r.input?.pictures = await picture(after: before, step: label)
    if asked != nil || rec.outcome == "undelivered" { check(label, rec.outcome == "hit", rec.line) }
    if let i = r.input { r.input?.line = InputRecord.line(i, focus: r.focus) }
    replace(r)
    return r
  }

  func replace(_ r: StepRecord) { if let i = steps.lastIndex(where: { $0.name == r.name && $0.atMs == r.atMs }) { steps[i] = r } }

  /// The menu item's path from the menu bar: `View › Split Down`.
  static func menuPath(_ item: NSMenuItem) -> String {
    var parts = [item.title], m = item.menu, n = 0
    while let menu = m, let sup = menu.supermenu, n < 8 {
      if let parent = sup.items.first(where: { $0.submenu === menu }), !parent.title.isEmpty { parts.insert(parent.title, at: 0) }
      m = sup; n += 1
    }
    return parts.joined(separator: " › ")
  }

  /// A main-menu item whose shortcut is this key event's (it didn't fire: disabled, or refused by validation).
  static func holder(of e: NSEvent) -> String? {
    let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let flags = e.modifierFlags.intersection(mask)
    let ign = e.charactersIgnoringModifiers ?? ""
    func walk(_ m: NSMenu?) -> NSMenuItem? {
      for i in m?.items ?? [] {
        if !i.keyEquivalent.isEmpty {
          var im = i.keyEquivalentModifierMask.intersection(mask)
          if let c = i.keyEquivalent.first, c.isUppercase, c.isLetter { im.insert(.shift) }
          if i.keyEquivalent.lowercased() == ign.lowercased(), im == flags { return i }
        }
        if let f = walk(i.submenu) { return f }
      }
      return nil
    }
    return walk(NSApp.mainMenu).map { menuPath($0) }
  }

  // MARK: pictures

  /// The bench window's picture before an input step, when pictures were asked for (`--pictures DIR`), taken in a
  /// run-loop turn of its own so it never lands in the step's stretches.
  func picture() async -> Data? {
    guard picturesDir != nil, let w = window, let png = Snapshot.png(of: w) else { return nil }
    await endTurn()
    return png
  }

  /// After the step: the window again; when it differs from `before`, both pictures and the difference are written and
  /// described. The comparison runs off the main thread, the capture in a turn of its own.
  func picture(after before: Data?, step: String) async -> InputPictures? {
    guard let dir = picturesDir, let b = before, let w = window, let a = Snapshot.png(of: w) else { return nil }
    let scale = Double(w.backingScaleFactor)
    let base = URL(fileURLWithPath: dir).appendingPathComponent("\(scenario)-rep\(rep)-\(steps.count)-\(Self.slug(step))").path
    await endTurn()
    return await Task.detached { InputPictures.write(before: b, after: a, base: base, scale: scale) }.value
  }

  /// Lets the stretch we're in close: work done before it never counts in the next step's stretches.
  func endTurn() async {
    let n = recorder.timeline.stretches.count
    _ = await recorder.wait(timeoutMs: 500) { [unowned self] in recorder.timeline.stretches.count > n }
  }

  static func slug(_ s: String) -> String {
    let t = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    let squeezed = t.split(separator: "-").joined(separator: "-")
    return String(squeezed.prefix(40)).isEmpty ? "step" : String(squeezed.prefix(40))
  }
}

extension InputPictures {
  /// Compares two PNGs of the window; under 25 changed pixels (a caret's blink is about that) is no change, nil. Else
  /// writes `base.before.png`, `.after.png` and `.diff.png` and returns them with the changed share and box.
  static func write(before: Data, after: Data, base: String, scale: Double) -> InputPictures? {
    func px(_ d: Data) -> Snapshot.Pixels? {
      guard let s = CGImageSourceCreateWithData(d as CFData, nil), let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
      return Snapshot.Pixels(image: i)
    }
    guard let pb = px(before), let pa = px(after) else { return nil }
    var rect: [Double]?
    var share = 1.0
    if pb.width == pa.width, pb.height == pa.height {
      var n = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
      for y in 0..<pb.height {
        for x in 0..<pb.width where pa.differs(pb, y * pb.width + x, threshold: 16) {
          n += 1; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
      }
      guard n >= 25 else { return nil }
      share = Double(n) / Double(pb.width * pb.height)
      let s = max(scale, 1)
      rect = [Stats.round(Double(x0) / s, 1), Stats.round(Double(y0) / s, 1), Stats.round(Double(x1 - x0 + 1) / s, 1), Stats.round(Double(y1 - y0 + 1) / s, 1)]
    }
    let dir = URL(fileURLWithPath: base).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bp = base + ".before.png", ap = base + ".after.png", dp = base + ".diff.png"
    guard (try? before.write(to: URL(fileURLWithPath: bp))) != nil, (try? after.write(to: URL(fileURLWithPath: ap))) != nil else { return nil }
    var diff: String?
    if rect != nil, let d = Snapshot.compare(pb, pa, threshold: 16).diff?.png(), (try? d.write(to: URL(fileURLWithPath: dp))) != nil { diff = dp }
    return InputPictures(before: bp, after: ap, diff: diff, changedPct: Stats.round(share * 100, 2), changedRect: rect)
  }
}
#endif

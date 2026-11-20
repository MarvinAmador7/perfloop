import Foundation

// What a step records about real input and focus (`run.press`, `run.type`, `run.key`, `run.click`; `steps[].input`,
// `steps[].focus`): plain values, so the result, its lines and the shortcut grammar are tested without a window (and
// build on Linux). Input.swift makes the events and fills these in.

/// A responder as a line names it: its class, its identifier (`NSView.identifier`, else the accessibility identifier)
/// and a label a person would read (a placeholder, a title, an accessibility label).
public struct ResponderRef: Codable, Sendable, Equatable {
  public var `class`: String
  public var identifier: String?
  public var label: String?
  public init(class c: String, identifier: String? = nil, label: String? = nil) { self.class = c; self.identifier = identifier; self.label = label }

  /// `NSTextField #palette.field "Search"`: the class, then whatever names it.
  public var text: String {
    var s = self.class
    if let i = identifier { s += " #\(i)" }
    if let l = label { s += " \"\(l)\"" }
    return s
  }
}

/// A window as the focus record names it. `role`: `bench` (the scenario's window), `child` (a panel, popover or sheet
/// the bench window owns), `other`.
public struct WindowRef: Codable, Sendable, Equatable {
  public var title: String
  public var `class`: String
  public var role: String
  public init(title: String, class c: String, role: String) { self.title = title; self.class = c; self.role = role }
  public var text: String { role == "bench" ? "the bench window" : "\(role) window \(self.class)" + (title.isEmpty ? "" : " \"\(title)\"") }
}

/// Where the keyboard goes at one moment: the key and main windows, the key window's first responder, and, when that
/// is a field editor (the NSTextView AppKit lends a text field while it edits), the view it edits. `inside`: the
/// identifiers of the focused view's ancestors, nearest first, so "focus is in the sidebar" can be said and checked.
public struct FocusRecord: Codable, Sendable, Equatable {
  public var keyWindow: WindowRef?
  public var mainWindow: WindowRef?
  /// nil: nothing has the keyboard (no key window, or its first responder is the window itself).
  public var firstResponder: ResponderRef?
  public var fieldEditor: Bool?
  /// The view the field editor edits (its delegate): the text field the user sees.
  public var editing: ResponderRef?
  public var inside: [String]?
  public init(keyWindow: WindowRef? = nil, mainWindow: WindowRef? = nil, firstResponder: ResponderRef? = nil, fieldEditor: Bool? = nil, editing: ResponderRef? = nil,
              inside: [String]? = nil) {
    self.keyWindow = keyWindow; self.mainWindow = mainWindow; self.firstResponder = firstResponder; self.fieldEditor = fieldEditor; self.editing = editing; self.inside = inside
  }

  /// The view a person would say has focus: the edited field, else the first responder.
  public var focused: ResponderRef? { editing ?? firstResponder }

  /// `#palette.field (field editor) in child window NSPanel`, `nothing (the bench window is key)`, `no key window`.
  public var text: String {
    guard let k = keyWindow else { return "no key window" }
    guard let f = focused else { return "nothing (\(k.text) is key)" }
    var s = f.text + (fieldEditor == true ? " (field editor)" : "")
    if let i = inside?.first { s += " inside #\(i)" }
    if k.role != "bench" { s += " in \(k.text)" }
    return s
  }

  /// Same keyboard target: the same window role and title and the same focused view.
  public func sameTarget(_ o: FocusRecord) -> Bool {
    keyWindow?.role == o.keyWindow?.role && keyWindow?.title == o.keyWindow?.title && keyWindow?.class == o.keyWindow?.class && focused == o.focused
  }
}

/// A step's focus before its action and after it settled (`steps[].focus`).
public struct FocusChange: Codable, Sendable, Equatable {
  public var before: FocusRecord
  public var after: FocusRecord
  /// The step's `expectFocus`, in words, when it had one; `matched` says whether `after` met it.
  public var expected: String?
  public var matched: Bool?
  public init(before: FocusRecord, after: FocusRecord, expected: String? = nil, matched: Bool? = nil) {
    self.before = before; self.after = after; self.expected = expected; self.matched = matched
  }
  public var changed: Bool { !before.sameTarget(after) }

  /// `focus: #filter (field editor)` when it stayed, `focus: #filter → NSTableView #rows` when it moved, and what the
  /// step expected when that didn't happen.
  public var text: String {
    var s = changed ? "focus: \(before.text) → \(after.text)" : "focus: \(after.text)"
    if let e = expected, matched == false { s += " (expected \(e))" }
    return s
  }
}

/// The window before and after an input step, when the step changed what is visible (`--pictures DIR`).
public struct InputPictures: Codable, Sendable, Equatable {
  public var before: String
  public var after: String
  /// Red where the two differ, over the dimmed `before`.
  public var diff: String?
  /// The share of the window's pixels that changed, and the box around them in points from the window's top-left
  /// corner: x, y, width, height.
  public var changedPct: Double
  public var changedRect: [Double]?
  public init(before: String, after: String, diff: String?, changedPct: Double, changedRect: [Double]?) {
    self.before = before; self.after = after; self.diff = diff; self.changedPct = changedPct; self.changedRect = changedRect
  }
}

/// What one `run.press` / `type` / `key` / `click` did (`steps[].input`). `outcome` is one word a check can read:
///
/// - press (and key, type): `fired` (the menu item expected, or any when none was), `fired-other` (another item than
///   the one expected), `not-fired` (no menu item fired; `taken` says what took the key instead, if anything),
///   `undelivered` (the events were still queued when the step ended);
/// - click: `hit` (the hit view is the one asked for, or inside it, or no view was asked for), `missed` (it hit
///   another view: something on top of the one asked for), `nothing` (no view at that point), `undelivered`.
public struct InputRecord: Codable, Sendable, Equatable {
  /// press | type | key | click.
  public var kind: String
  /// The keys as pressed, in the menu's notation (`⇧⌘D`); for `type`, the text.
  public var keys: String?
  public var text: String?
  /// The virtual key and the characters the layout gave it (`charactersIgnoringModifiers`), for the first key.
  public var keyCode: Int?
  public var characters: String?
  /// The keyboard layout the characters came from (`com.apple.keylayout.US`).
  public var layout: String?
  public var outcome: String
  /// The menu item that fired (its title and path), the one expected, and the action's target.
  public var menuItem: String?
  public var menuPath: String?
  public var expected: String?
  public var target: ResponderRef?
  /// A menu item that has these keys but didn't fire (disabled, or not validated).
  public var holder: String?
  /// What took a key no menu item fired for: `key-equivalent` (a view in the window, e.g. a button's shortcut or a
  /// SwiftUI `.keyboardShortcut`), `responder` (`responder` handled it in the responder chain), `unhandled` (it went
  /// up the responder chain to its end, where AppKit beeps).
  public var taken: String?
  public var responder: ResponderRef?
  /// type: how many keys went out, and how many of them nobody handled.
  public var count: Int?
  public var unhandled: Int?
  /// Characters the layout has no key for, typed as text (as an input method would insert them).
  public var asText: String?
  /// click: the point in window coordinates (points, origin bottom-left as AppKit has it), the view asked for, the view
  /// AppKit hit-tested there, and what took the mouse-down: `consumer` (a view, or the gesture recognizer's view) and
  /// `consumerKind` (`view`, `gesture-recognizer`, `nobody`).
  public var point: [Double]?
  public var asked: ResponderRef?
  public var hit: ResponderRef?
  public var consumer: ResponderRef?
  public var consumerKind: String?
  public var recognizer: String?
  /// What AppKit did that a reader should know (the window wasn't key, so the click made it key; a hosting view).
  public var notes: [String]?
  public var pictures: InputPictures?
  /// How long the key down (or mouse down) waited on the app's queue, from the step's start to AppKit taking it (ms;
  /// counted in the step's numbers). About 0.1 ms on a real window; more means the main thread
  /// was busy, or AppKit held events for its update cycle. nil: AppKit never took it.
  public var queueMs: Double?
  /// The one line a reader reads: what was done, what happened, where the focus went and how much of the window changed
  /// (`press ⌘K → fired menu 'Search…' (File › Search…); focus: nothing → #palette.field (field editor)`).
  public var line: String

  public init(kind: String, outcome: String, line: String = "") { self.kind = kind; self.outcome = outcome; self.line = line }

  /// Whether the action did what was asked: fired the expected item (or any), hit the view asked for.
  public var ok: Bool { ["fired", "hit"].contains(outcome) || (kind != "press" && outcome == "delivered") }

  /// The record's line: what was done, then what happened.
  public func describe() -> String {
    let what: String = switch kind {
    case "type": "type '\(text ?? "")'"
    case "click": "click " + (asked.map { $0.identifier.map { "#\($0)" } ?? $0.text } ?? point.map { "(\(Self.n($0[0])), \(Self.n($0[1])))" } ?? "")
    default: "\(kind) \(keys ?? "?")"
    }
    var then: String
    switch outcome {
    case "fired": then = "fired menu '\(menuItem ?? "?")'" + (menuPath.map { $0 != menuItem ? " (\($0))" : "" } ?? "") + (target.map { " → \($0.class)" } ?? "")
    case "fired-other": then = "fired menu '\(menuItem ?? "?")'" + (menuPath.map { $0 != menuItem ? " (\($0))" : "" } ?? "") + ", not '\(expected ?? "?")'"
    case "not-fired":
      then = "no menu item fired" + (expected.map { " (expected '\($0)')" } ?? "")
      if let h = holder { then += "; '\(h)' has \(keys ?? "these keys") but didn't fire (disabled?)" }
      then += taken.map { "; " + Self.taken($0, responder) } ?? ""
    case "delivered":
      then = kind == "type" ? "\(count ?? 0) key(s) to \(responder?.text ?? "the first responder")" : "to \(responder?.text ?? "the first responder")"
      if let t = taken, t != "responder" { then += "; " + Self.taken(t, responder) }
      if let u = unhandled, u > 0 { then += "; \(u) of \(count ?? u) unhandled" }
      if let a = asText { then += "; typed as text (no key for it on the layout): \(a)" }
    case "hit", "missed":
      then = "hit \(hit?.text ?? "nothing")"
      if outcome == "missed", let a = asked { then += ", not \(a.text) (something on top of it took the point)" }
      switch consumerKind {
      case "gesture-recognizer": then += ", taken by \(recognizer ?? "a gesture recognizer") on \(consumer?.text ?? "?")"
      case "nobody": then += ", taken by nobody (it went up the responder chain unhandled)"
      default: if let c = consumer, c != hit { then += ", taken by \(c.text)" } else if consumer != nil { then += ", which took it" }
      }
    case "nothing": then = "no view at that point"
    case "undelivered": then = "not delivered: the events were still queued when the step ended (a modal loop, or the run loop blocked)"
    default: then = outcome
    }
    return "\(what) → \(then)"
  }

  static func taken(_ t: String, _ r: ResponderRef?) -> String {
    switch t {
    case "key-equivalent": "taken as a key equivalent by a view in the window (a button's shortcut, a SwiftUI .keyboardShortcut)"
    case "unhandled": "unhandled: it went up the responder chain" + (r.map { " from \($0.text)" } ?? "") + " to its end"
    default: "handled by \(r?.text ?? "the responder chain")"
    }
  }

  /// The line with the step's focus and the pictures' change: `press ⌘K → fired menu 'Search…'; focus: … → …`.
  public static func line(_ r: InputRecord, focus: FocusChange?) -> String {
    var s = r.describe()
    if let f = focus { s += "; " + f.text }
    if let p = r.pictures { s += "; changed \(n(p.changedPct)) % of the window" + (p.changedRect.map { " (x \(n($0[0])), y \(n($0[1])), \(n($0[2]))×\(n($0[3])) pt)" } ?? "") }
    return s
  }

  static func n(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(format: "%.1f", d) }
}

/// A keyboard shortcut as a person writes it: `⇧⌘D`, `⌘K`, `cmd+shift+d`, `ctrl-opt-x`, `⌘↑`, `esc`. The modifiers
/// (⌃ ⌥ ⇧ ⌘, or their names) and one key: a character (a letter in either case: `⌘K` is ⌘k, as menus write it;
/// ⇧ only when written), or a named key (`Shortcut.named`).
public struct Shortcut: Sendable, Equatable {
  public var control = false, option = false, shift = false, command = false
  /// The key: one character (as written; the layout decides which key types it), or a named key's name.
  public var key: String
  public var named: Bool { Self.named[key] != nil }

  public init(key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
    self.key = key; self.control = control; self.option = option; self.shift = shift; self.command = command
  }

  /// Named keys and their virtual key codes (Carbon's kVK_*, the same on every layout).
  public static let named: [String: Int] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwardDelete": 117, "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126, "enter": 76,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
  ]
  /// What a named key is written as in a menu.
  public static let symbols: [String: String] = [
    "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "⎋", "forwardDelete": "⌦", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
    "left": "←", "right": "→", "down": "↓", "up": "↑", "enter": "⌤",
  ]
  static let aliases: [String: String] = [
    "esc": "escape", "⎋": "escape", "enter": "enter", "⌤": "enter", "↩": "return", "⏎": "return", "ret": "return", "⇥": "tab", "␣": "space", "spacebar": "space",
    "⌫": "delete", "backspace": "delete", "⌦": "forwardDelete", "forwarddelete": "forwardDelete", "del": "forwardDelete", "↖": "home", "↘": "end",
    "⇞": "pageUp", "pageup": "pageUp", "⇟": "pageDown", "pagedown": "pageDown", "←": "left", "→": "right", "↓": "down", "↑": "up",
    "arrowleft": "left", "arrowright": "right", "arrowdown": "down", "arrowup": "up",
  ]

  /// Parses a shortcut; nil (with the reason) when it isn't one.
  public static func parse(_ s: String) -> Result<Shortcut, ShortcutError> {
    var rest = Substring(s.trimmingCharacters(in: .whitespaces))
    var sc = Shortcut(key: "")
    // Symbols first: ⌃⌥⇧⌘ in any order, then the key.
    let symbols: [Character: WritableKeyPath<Shortcut, Bool>] = ["⌃": \.control, "⌥": \.option, "⇧": \.shift, "⌘": \.command]
    while let c = rest.first, let kp = symbols[c], rest.count > 1 { sc[keyPath: kp] = true; rest = rest.dropFirst() }
    // Then words joined by + or - (cmd+shift+d, ctrl-opt-x); a lone "+" or "-" is the key itself.
    let words: [String: WritableKeyPath<Shortcut, Bool>] = ["cmd": \.command, "command": \.command, "shift": \.shift, "opt": \.option, "option": \.option, "alt": \.option,
                                                            "ctrl": \.control, "control": \.control]
    var parts: [String] = []
    if rest.count > 1, rest.contains(where: { $0 == "+" || $0 == "-" }) {
      var cur = ""
      for c in rest {
        if (c == "+" || c == "-"), !cur.isEmpty { parts.append(cur); cur = "" } else { cur.append(c) }
      }
      parts.append(cur)
    } else { parts = [String(rest)] }
    for p in parts.dropLast() {
      guard let kp = words[p.lowercased()] else { return .failure(.init("'\(p)' in '\(s)' isn't a modifier (⌃ ⌥ ⇧ ⌘, or ctrl, opt, shift, cmd)")) }
      sc[keyPath: kp] = true
    }
    guard let last = parts.last, !last.isEmpty else { return .failure(.init("'\(s)' names no key")) }
    let lower = last.lowercased()
    if let a = aliases[last] ?? aliases[lower] { sc.key = a } else if named[last] != nil { sc.key = last }
    else if let n = named.keys.first(where: { $0.lowercased() == lower }) { sc.key = n }
    else if last.count == 1 { sc.key = last }
    else { return .failure(.init("'\(last)' in '\(s)' is neither one character nor a key name (\(named.keys.sorted().joined(separator: ", ")))")) }
    // A letter is its key in either case, as a menu writes ⌘K for ⌘k: ⇧ only when written.
    if sc.key.count == 1, let c = sc.key.first, c.isLetter { sc.key = c.lowercased() }
    return .success(sc)
  }

  /// In the menu's notation and order: ⌃⌥⇧⌘, then the key (a letter upper-case, as menus show it).
  public var display: String {
    var s = ""
    if control { s += "⌃" }; if option { s += "⌥" }; if shift { s += "⇧" }; if command { s += "⌘" }
    return s + (Self.symbols[key] ?? (named ? key.uppercased() : key.uppercased()))
  }
}

public struct ShortcutError: Error, Equatable, CustomStringConvertible {
  public var description: String
  init(_ s: String) { description = s }
}

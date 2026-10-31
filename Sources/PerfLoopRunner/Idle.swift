import Foundation
import PerfLoopKit
#if canImport(IOKit)
import IOKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the idle gate's readings come from.
public protocol IdleSource {
  func read() -> IdleReading
}

/// This Mac: IOKit `IOHIDSystem`'s `HIDIdleTime` (ns since the last keyboard, mouse or trackpad event), the screen lock
/// (`CGSSessionScreenIsLocked`) and the frontmost app (the owner of the frontmost normal window). Elsewhere: unknown,
/// so the gate waits (and `--force` runs anyway).
public struct HIDIdleSource: IdleSource {
  public init() {}
  public func read() -> IdleReading {
    #if canImport(IOKit) && canImport(CoreGraphics)
    return IdleReading(idle: Self.hidIdleSeconds(), frontmost: Self.frontmostApp(), locked: Self.screenLocked())
    #else
    return IdleReading(idle: nil)
    #endif
  }

  #if canImport(IOKit) && canImport(CoreGraphics)
  public static func hidIdleSeconds() -> Double? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
    if let n = v as? NSNumber { return n.doubleValue / 1e9 }
    if let d = v as? Data, d.count >= 8 { return Double(d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 1e9 }
    return nil
  }

  public static func screenLocked() -> Bool? {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
  }

  /// The owner of the frontmost on-screen window at the normal level (the window list is front to back).
  public static func frontmostApp() -> String? {
    guard let ws = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    return ws.first { ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowOwnerName as String] as? String
  }
  #endif
}

/// The testing hook (`--idle-from FILE`, `PERFLOOP_IDLE_FROM`): the reading is the file's text, read afresh each poll
/// (`idle=130 frontmost=Xcode locked=0`, or seconds). A missing file reads as unknown.
public struct FileIdleSource: IdleSource {
  public let path: String
  public init(path: String) { self.path = path }
  public func read() -> IdleReading {
    guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return IdleReading(idle: nil) }
    return IdleReading(text: t)
  }
}

/// A closure, for tests.
public struct ScriptedIdleSource: IdleSource {
  let f: () -> IdleReading
  public init(_ f: @escaping () -> IdleReading) { self.f = f }
  public func read() -> IdleReading { f() }
}

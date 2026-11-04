import AppKit
import SlowListKit

// The app: an AppKit window whose content is the SwiftUI list over an AppKit status line (ListContainerView), the same
// view the bench hosts on its fixtures.
final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  func applicationDidFinishLaunching(_ n: Notification) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = "SlowList"
    w.contentView = MainActor.assumeIsolated { ListContainerView(model: ListModel.sample(count: 1000)) }
    w.center(); w.makeKeyAndOrderFront(nil)
    window = w
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

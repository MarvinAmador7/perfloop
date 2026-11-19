import AppKit
import SlowListKit

// The app: an AppKit window whose content is the SwiftUI list over an AppKit status line (ListContainerView), the same
// view the bench hosts on its fixtures, and its menu bar (SlowListAppDelegate, which the bench's `menu` scenario runs in).
let app = NSApplication.shared
let delegate = SlowListAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

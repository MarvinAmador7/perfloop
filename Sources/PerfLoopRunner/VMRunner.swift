import Foundation
import PerfLoopKit

/// `vm:tart/NAME`: a macOS VM on this Mac (SPEC §4.2). Not built yet: this says what's missing instead of pretending.
///
/// The plan, when it is wanted: `tart run NAME --no-graphics` in the background (the guest still has a paravirtualised
/// Metal display, so the window renders), `tart ip NAME` for its address, then exactly the ssh runner against
/// `admin@IP` with the runner name `vm:tart/NAME`, so its results are their own machine in the ledger. Its numbers are
/// CPU ms only: PMU counters aren't available in guests (instructions read zero) and display-link cadence and hitches in
/// a guest aren't trusted, so a VM screens code changes and never decides a full. Needed first, all the owner's call:
/// Tart (`brew install cirruslabs/cli/tart`), a macOS image (~25 GB: `tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest NAME`),
/// this Mac's key in the guest's `~/.ssh/authorized_keys`, and automatic login in the guest (a GUI session for windows).
public enum VMRunner {
  public static func make(tool: String, name: String) throws -> Runner {
    guard tool == "tart" else { throw PLError.usage("vm:\(tool)/\(name): only Tart VMs are planned (vm:tart/NAME)") }
    let have = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tart") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/tart")
    let missing = have
      ? "Tart is installed, but the vm runner isn't built yet"
      : "Tart isn't installed (brew install cirruslabs/cli/tart), and a macOS image is ~25 GB (tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest \(name))"
    throw PLError.usage("""
    vm:tart/\(name): not available: \(missing). Until it is, a VM can be used as an ssh runner: start it (tart run \(name) --no-graphics &), \
    authorize this Mac's key in it, turn on automatic login there, then --runner ssh://admin@$(tart ip \(name)). \
    Its numbers are CPU ms only (no PMU counters, untrusted frame cadence in a guest): screens, never a full's decision
    """)
  }
}

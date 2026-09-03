import AppKit
@testable import folino
import Testing

/// Spec §2.9.3: a score opened while another score window is up becomes a TAB of that window.
///
/// **These are characterization tests of AppKit, and that is the point.** The shipped implementation guarded on
/// `window.tabGroup == nil` and was measured on 2026-09-03 to skip `addTabbedWindow` every single time, so every
/// score after the first opened as a standalone window. The cause was an assumption about `tabGroup` that nothing
/// tested. The first test below is that assumption, written down and asserted.
@MainActor
struct MacScoreWindowTabbingTests {
    /// Off-screen and never ordered front, so a unit test never disturbs the host app's window list. `.titled` is
    /// required: an untitled window cannot participate in tabbing at all, and these tests are about tabbing.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "com.KeyNumber.Folino.score.test"
        window.tabbingMode = .preferred
        return window
    }

    /// The regression test for the §2.9.3 failure. Two windows that share a tabbing identifier but have never been
    /// joined must still need joining — even though each may already report a tab group of its own, which is what
    /// `tabbingMode = .preferred` gives it. The old `window.tabGroup == nil` condition answers "no" here, which is
    /// how the feature came to be silently off.
    @Test func `a window that has never been joined still needs joining`() {
        let host = makeWindow()
        let newcomer = makeWindow()
        // The assumption that broke §2.9.3, pinned. If this ever fails, the old `tabGroup == nil` condition would
        // have answered this test correctly and the test below no longer discriminates between the two — which
        // would make it worthless as a regression test, not merely wrong.
        #expect(
            newcomer.tabGroup != nil,
            "a tabbing window gets a group of its own, so `tabGroup == nil` cannot mean 'not joined yet'",
        )
        #expect(MacScoreWindowTabbing.needsJoining(newcomer, host: host))
    }

    /// The case the guard is actually for: once the newcomer IS in the host's group, joining again is wrong.
    @Test func `a window already in the host's tab group does not need joining`() {
        let host = makeWindow()
        let newcomer = makeWindow()
        host.addTabbedWindow(newcomer, ordered: .above)
        #expect(newcomer.tabGroup === host.tabGroup)
        #expect(!MacScoreWindowTabbing.needsJoining(newcomer, host: host))
    }

    /// Two windows in two DIFFERENT groups are not the same case: a torn-off tab, or a window whose group the user
    /// broke apart, still needs joining back.
    @Test func `a window in a different tab group needs joining`() {
        let host = makeWindow()
        let newcomer = makeWindow()
        host.addTabbedWindow(newcomer, ordered: .above)
        newcomer.moveTabToNewWindow(nil)
        #expect(MacScoreWindowTabbing.needsJoining(newcomer, host: host))
    }
}

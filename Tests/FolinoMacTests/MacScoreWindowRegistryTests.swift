import AppKit
@testable import folino
import Testing

/// Spec §2.9.3 and §2.9.5: the registry is what knows which score windows exist, so it is what decides which window
/// a newcomer tabs onto and whether closing one leaves the app with no score on screen.
@MainActor
struct MacScoreWindowRegistryTests {
    /// Off-screen and never ordered front, so a unit test never disturbs the host app's window list.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true,
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func `registering twice keeps one entry`() {
        let registry = MacScoreWindowRegistry()
        let window = makeWindow()
        registry.register(window)
        registry.register(window)
        #expect(registry.windows.count == 1)
    }

    @Test func `unregister empties the registry`() {
        let registry = MacScoreWindowRegistry()
        let window = makeWindow()
        registry.register(window)
        #expect(!registry.isEmpty)
        registry.unregister(window)
        #expect(registry.isEmpty)
    }

    @Test func `the tab host is the frontmost registered window that is not the newcomer`() {
        let registry = MacScoreWindowRegistry()
        let older = makeWindow()
        let newer = makeWindow()
        let newcomer = makeWindow()
        registry.register(older)
        registry.register(newer)
        // Front-to-back as AppKit would report it: the newcomer is frontmost, `newer` next.
        let host = registry.tabHost(excluding: newcomer, frontToBack: [newcomer, newer, older])
        #expect(host === newer)
    }

    @Test func `an unregistered window is never a tab host`() {
        let registry = MacScoreWindowRegistry()
        let stranger = makeWindow()
        let registered = makeWindow()
        let newcomer = makeWindow()
        registry.register(registered)
        // `stranger` is in front of `registered` but is not a score window — the library, or Settings.
        let host = registry.tabHost(excluding: newcomer, frontToBack: [newcomer, stranger, registered])
        #expect(host === registered)
    }

    @Test func `the first score window has no tab host`() {
        let registry = MacScoreWindowRegistry()
        let newcomer = makeWindow()
        #expect(registry.tabHost(excluding: newcomer, frontToBack: [newcomer]) == nil)
    }

    @Test func `the library is shown when the last score window goes`() {
        let registry = MacScoreWindowRegistry()
        var shown = 0
        registry.showLibrary = { shown += 1 }
        let window = makeWindow()
        registry.register(window)
        registry.showLibraryIfNoScoreWindowsRemain()
        #expect(shown == 0)
        registry.unregister(window)
        registry.showLibraryIfNoScoreWindowsRemain()
        #expect(shown == 1)
    }

    @Test func `quitting does not summon the library`() {
        let registry = MacScoreWindowRegistry()
        var shown = 0
        registry.showLibrary = { shown += 1 }
        registry.isTerminating = true
        registry.showLibraryIfNoScoreWindowsRemain()
        #expect(shown == 0)
    }
}

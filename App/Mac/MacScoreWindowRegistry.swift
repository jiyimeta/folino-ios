import AppKit
import Foundation

/// The live score windows of this process, plus the one way back to the library.
///
/// **Why the shell needs a registry at all.** Three of §2.9's five rules are about *the set of score windows*, not
/// about any one of them: a newly opened score joins the frontmost existing score window as a tab (§2.9.3), closing
/// the last one puts the library on screen (§2.9.5), and a window whose score is gone closes itself and shows the
/// library (§2.9.4). SwiftUI publishes no such set — `WindowGroup(for:)` hands each window its own value and nothing
/// else — and `NSApp.windows` cannot be filtered down to it, because the library, Settings and every AppKit panel are
/// in there too. So the score windows announce themselves, through `MacWindowTabAssist`'s probe.
///
/// **References are weak, and that is not an optimization.** AppKit owns a window's lifetime; a strong reference here
/// would keep a closed window (and the whole SwiftUI tree behind it, `EditorViewModel` included) alive for the life of
/// the process. `unregister` runs from `NSWindow.willCloseNotification` and is the ordinary path; the weak boxes are
/// the backstop for a window that goes away without one.
///
/// **Nothing here touches AppKit state.** It answers questions — who should host a tab, is anything left — and the
/// probe acts on the answers. That is what makes it testable without showing a window.
@MainActor
final class MacScoreWindowRegistry {
    /// The process's one registry. Production code goes through this; a fresh `MacScoreWindowRegistry()` exists so
    /// tests can work against an empty, isolated instance — the same arrangement `MacEditorRegistry` uses.
    static let shared = MacScoreWindowRegistry()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) {
            self.window = window
        }
    }

    private var boxes: [WeakWindow] = []

    /// Opens (or focuses) the library window. Installed by `MacWindowTabAssist`'s `updateNSView` from every score
    /// window, so it is refreshed on every body pass of every score window and is therefore at its freshest exactly
    /// when it is needed: the moment the last score window closes, microseconds after that window's last update.
    /// `MacLibraryWindowPresentation` installs it too, from the library window itself — last-writer-wins across score
    /// windows can otherwise leave this holding a closed window's action, and the library's own is the one installer
    /// that cannot belong to a score window. See that file for the full reasoning.
    ///
    /// It is stored rather than reached for because the callers are AppKit — a `willClose` notification handler has
    /// no SwiftUI environment, and `openWindow` is the only thing that can create the single-instance `Window` scene
    /// when none exists.
    var showLibrary: (() -> Void)?

    /// Set by `MacAppDelegate.applicationShouldTerminate`. ⌘Q closes every window, which would otherwise read as
    /// "the last score window closed" and open the library on the way out of the process.
    var isTerminating = false

    /// The live registered windows, in registration order.
    var windows: [NSWindow] {
        boxes.compactMap(\.window)
    }

    var isEmpty: Bool {
        windows.isEmpty
    }

    func register(_ window: NSWindow) {
        boxes.removeAll { $0.window == nil }
        guard !boxes.contains(where: { $0.window === window }) else { return }
        boxes.append(WeakWindow(window))
    }

    func unregister(_ window: NSWindow) {
        boxes.removeAll { $0.window === window || $0.window == nil }
    }

    /// The window `newcomer` should become a tab of, or `nil` when it is the only score window.
    ///
    /// `frontToBack` is AppKit's own front-to-back ordering (`NSApp.orderedWindows`), passed in rather than read here
    /// so this is a function of its arguments and can be tested. Front-most first is what makes "the score window you
    /// were last looking at" the host rather than whichever window happened to be registered first — the newcomer
    /// itself is frontmost at the moment this is asked, which is why it is excluded by identity.
    ///
    /// The fallback exists because `orderedWindows` omits windows that are not on screen (minimized, or on another
    /// Space): a registered score window that AppKit will not list is still a legal tab host, and tabbing onto it is
    /// better than minting a standalone window the user did not ask for.
    func tabHost(excluding newcomer: NSWindow, frontToBack: [NSWindow]) -> NSWindow? {
        let registered = windows
        for candidate in frontToBack
            where candidate !== newcomer && registered.contains(where: { $0 === candidate })
        {
            return candidate
        }
        return registered.first { $0 !== newcomer }
    }

    /// §2.9.5 — no score open means the library is on screen. A no-op while any score window is left, and while the
    /// app is quitting.
    func showLibraryIfNoScoreWindowsRemain() {
        guard !isTerminating, isEmpty else { return }
        showLibrary?()
    }
}

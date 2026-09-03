import AppKit
import SwiftUI

/// Makes the library a *chooser over the score* rather than a window living in a Space of its own (design §2.9.2).
/// Place one instance inside the library window's content; there is no SwiftUI-side equivalent of any of these
/// properties, which is why this is a probe at all.
///
/// Three AppKit facts do the work:
///
/// * **`.fullScreenAuxiliary`** lets this window be shown on top of a full-screen window of the same app instead of
///   forcing a Space switch. Without it, ⌘O from a full-screen score animates the user away from the score they were
///   reading — which is exactly what §2.9.2 forbids.
/// * **`.moveToActiveSpace`** covers the re-summon: a library window that was left open on another Space comes to
///   the Space the user is on, rather than the user being taken to it.
/// * **`tabbingMode = .disallowed`** keeps the library out of the score windows' tab group. They share no tabbing
///   identifier, so AppKit would not merge them on its own — but Window ▸ Merge All Windows does not consult
///   identifiers, and a library folded in as a tab of a score window is a window that cannot then be dismissed
///   independently.
struct MacLibraryWindowPresentation: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context _: Context) -> NSView {
        MacLibraryWindowProbe()
    }

    /// Installs the registry's way back to the library from the library window itself — a second installer alongside
    /// `MacWindowTabAssist`'s.
    ///
    /// **Why a second one.** `showLibrary` is last-writer-wins across score windows, so it can end up holding the
    /// `OpenWindowAction` captured by a score window that has since closed (open A, open B, let A re-render, close A,
    /// close B) — and §2.9.5 would then do nothing when the last score window goes, leaving the app with no windows
    /// and no library short of ⌘O. The library window's own action is the one installer that cannot belong to a
    /// *score* window: it comes from a `Window` scene rather than from a `WindowGroup` member, so any session in
    /// which the library has been on screen at least once carries an action whose window is the library's own
    /// single instance. That is hardening, not a proof — whether an `OpenWindowAction` outlives the window that
    /// captured it is the underlying question, and it is on the QA sheet rather than settled here.
    ///
    /// Assigning to a stored property of a plain `@MainActor` class is not a SwiftUI state write — it invalidates no
    /// view — which is what makes it safe from `updateNSView`; `MacWindowTabAssist.updateNSView` and
    /// `MacImportedScoreClaim` record the long version.
    func updateNSView(_: NSView, context _: Context) {
        MacScoreWindowRegistry.shared.showLibrary = { openWindow(id: MacWindowID.library) }
    }
}

/// The probe behind `MacLibraryWindowPresentation`. Deferred and latched exactly as `MacWindowTabAssist`'s probe is —
/// see its doc comment for the measurement that makes the `DispatchQueue.main.async` hop mandatory rather than
/// tidy.
private final class MacLibraryWindowProbe: NSView {
    private var applied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !applied else { return }
        applied = true
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            // `.fullScreenPrimary` / `.fullScreenAuxiliary` / `.fullScreenNone` are an at-most-one group, and
            // SwiftUI gives a resizable window scene `.fullScreenPrimary` by default — which is what lets the score
            // window go full screen at all. Leaving both bits set on the library is a conflicting mask that resolves
            // as *primary*, i.e. the library taking a Space of its own: precisely the §2.9.2 failure this probe is
            // here to prevent. So the primary bit comes off first.
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.tabbingMode = .disallowed
        }
    }
}

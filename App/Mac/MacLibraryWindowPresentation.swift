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
    func makeNSView(context _: Context) -> NSView {
        MacLibraryWindowProbe()
    }

    func updateNSView(_: NSView, context _: Context) {}
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
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.tabbingMode = .disallowed
        }
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// An edge-triggered "bring this rectangle into view" request, in the hosted content's own coordinate space.
///
/// The token is what makes it edge-triggered: `updateNSView` runs on every body evaluation of the container (a
/// playback tick re-evaluates it sixty times a second), and re-issuing the same scroll on each of those would pin the
/// view and make manual scrolling impossible. The coordinator remembers the last token it applied and ignores repeats.
struct MacDeckScrollRequest: Equatable {
    let token: Int
    let rect: CGRect
}

/// The magnification range the host allows, carried by the reference implementation. 0.25 is small enough to see a
/// multi-page spread at once; 4.0 is where the engraving is being inspected rather than read. Non-generic so the
/// container can clamp its own fit-to-window seed against the same numbers the scroll view enforces.
enum MacScoreMagnification {
    static let minimum: CGFloat = 0.25
    static let maximum: CGFloat = 4.0
}

/// Hosts a SwiftUI page deck inside an `NSScrollView` whose `allowsMagnification` does the zooming.
///
/// **This is the whole reason Page mode uses an AppKit host rather than a SwiftUI `ScrollView`.** AppKit re-rasterizes
/// the document layer at the current magnification, so the engraving stays vector-sharp at any zoom — the layer tree
/// is redrawn at the new scale rather than a 1x raster being stretched. Nothing in here may put the zoom into the
/// SwiftUI content: a `.scaleEffect` on the deck would render at unit size and scale the resulting bitmap, which looks
/// right at 1x and turns to mush at 4x. The magnification lives on the scroll view and only on the scroll view.
///
/// Adapted from swift-sheet-music's own macOS example host (`Examples/Apple/SheetMusicExample/macOS`), with the
/// example's fixed page list replaced by a generic content closure and its `ObjectIdentifier` rebuild gate replaced by
/// an explicit generation counter (see `contentGeneration`).
struct MagnifyingScoreScrollView<Content: View>: NSViewRepresentable {
    /// The scroll view's magnification, mirrored out at the end of every pinch so an external write (fit-to-window on
    /// first layout, a future "Actual Size" command) can apply.
    @Binding var magnification: CGFloat
    /// Bumped by the container every time it installs a new engraving. `updateNSView` reassigns the hosting view's
    /// `rootView` only when this moves, so a body re-evaluation that changed nothing structural — a playback tick, a
    /// scroll — never walks the whole page deck again. Everything inside the deck that changes more often than the
    /// engraving does (the playback cursor, the AB-loop range) reaches it through observation instead, which
    /// invalidates the leaf that reads it rather than the whole tree.
    let contentGeneration: Int
    /// Programmatic scroll target, or `nil` for none. See `MacDeckScrollRequest`.
    let scrollRequest: MacDeckScrollRequest?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = MacScoreMagnification.minimum
        scrollView.maxMagnification = MacScoreMagnification.maximum
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // A page deck is scrolled diagonally as often as it is scrolled along one axis — predominant-axis scrolling
        // would lock a two-finger swipe to whichever direction it started in.
        scrollView.usesPredominantAxisScrolling = false
        // The reading surface's ground is painted once, at `MacReaderRootScreen`. Drawing a second one here is exactly
        // the two-sources-of-truth problem that put a dark slab behind the spinner before; the individual page cards
        // paint their own paper white, which is a different thing — that white is the sheet, not the desk.
        scrollView.drawsBackground = false

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        scrollView.magnification = magnification
        context.coordinator.lastGeneration = contentGeneration

        // `NSScrollView` fires `didEndLiveMagnify` once the gesture settles; mirroring its final value into the
        // binding is what lets a later external write be recognized as a change at all.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidEnd(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.willStartLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView,
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.binding = $magnification
        if context.coordinator.lastGeneration != contentGeneration {
            context.coordinator.lastGeneration = contentGeneration
            (nsView.documentView as? NSHostingView<Content>)?.rootView = content()
        }
        // Apply external magnification writes. Skipped mid-pinch: writing back during a live gesture fights AppKit's
        // own update and reads as the zoom snapping backwards under the fingers.
        if !context.coordinator.isLiveMagnifying,
           abs(nsView.magnification - magnification) > 0.001
        {
            nsView.magnification = magnification
        }
        if let request = scrollRequest, context.coordinator.lastScrollToken != request.token {
            context.coordinator.lastScrollToken = request.token
            nsView.documentView?.scrollToVisible(request.rect)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// `@MainActor` because both notifications are posted by AppKit on the main thread and the handlers touch the
    /// SwiftUI binding.
    @MainActor
    final class Coordinator: NSObject {
        var binding: Binding<CGFloat>?
        var lastGeneration = -1
        var lastScrollToken = -1
        var isLiveMagnifying = false

        @objc func willStartLiveMagnify(_: Notification) {
            isLiveMagnifying = true
        }

        @objc func magnificationDidEnd(_ notification: Notification) {
            isLiveMagnifying = false
            guard let scrollView = notification.object as? NSScrollView else { return }
            binding?.wrappedValue = scrollView.magnification
        }
    }
}
#endif

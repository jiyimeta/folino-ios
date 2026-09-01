#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// An edge-triggered "put the view here" request, in the hosted content's own coordinate space.
///
/// The token is what makes it edge-triggered: `updateNSView` runs on every body evaluation of the container (a
/// playback tick re-evaluates it sixty times a second), and re-issuing the same scroll on each of those would pin the
/// view and make manual scrolling impossible. The coordinator remembers the last token it applied and ignores repeats.
struct MacScoreScrollRequest: Equatable {
    /// Where the scroll view should end up. Two shapes because the two containers ask different questions.
    enum Target: Equatable {
        /// Scroll the minimum amount that brings this rectangle into view. Page mode's page turn: a sheet is either
        /// on screen or it is not, and moving it any further than necessary would drag the reader's eye.
        case visible(CGRect)
        /// Put the clip view's bounds origin exactly here, in the hosted content's unmagnified coordinates.
        /// Horizontal mode's follow, which does not want "make the measure visible" but the specific offset the
        /// shared follow math computed — pinning the playing measure near the leading edge rather than letting it
        /// ride the trailing one.
        case origin(CGPoint)
    }

    let token: Int
    let target: Target
}

/// The scroll view's live viewport, mirrored out of AppKit for a container that draws something OUTSIDE the scroll
/// view which nonetheless has to track the content inside it.
///
/// **Only Horizontal mode needs this, and only because of its sticky leading pane.** That pane is a SwiftUI overlay
/// sitting on top of the scroll view — it is not scrolled by AppKit — so it can only stay glued to the staves if it is
/// told, every frame, where the content went and how big it is being drawn. Page and Vertical draw nothing over their
/// scroll view and pass `nil`, which registers no observer at all: their bodies re-render exactly as often as they did
/// before this existed.
///
/// `@Observable` rather than a `Binding` so the reads are per-property and per-view: the container reads `scroll` and
/// `magnification` to place the pane, and the score strip inside the hosting view reads neither, so a scroll frame
/// never reaches the engraving.
@MainActor
@Observable
final class MacScoreViewportState {
    /// The clip view's bounds origin, in the hosted content's own unmagnified coordinates. Passed through raw,
    /// including the brief negatives an elastic over-scroll produces — a pane that froze at the document edge while
    /// the score bounced past it would visibly come unstuck.
    var scroll: CGPoint = .zero
    /// The scroll view's magnification, tracked continuously — including mid-pinch, which `magnification`'s binding
    /// deliberately is not. See `MagnifyingScoreScrollView.magnification`.
    var magnification: CGFloat = 1
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
    ///
    /// **The control channel, not the observation one.** It is deliberately not written mid-gesture: a container that
    /// re-rendered on every frame of a pinch would walk its whole body at gesture frame rate for a value only the
    /// scroll view is using. A container that genuinely needs the live value — Horizontal, whose sticky pane has to
    /// scale in lock-step with the score under it — asks for `viewportState` instead.
    @Binding var magnification: CGFloat
    /// Bumped by the container every time it installs a new engraving. `updateNSView` reassigns the hosting view's
    /// `rootView` only when this moves, so a body re-evaluation that changed nothing structural — a playback tick, a
    /// scroll — never walks the whole page deck again. Everything inside the deck that changes more often than the
    /// engraving does (the playback cursor, the AB-loop range) reaches it through observation instead, which
    /// invalidates the leaf that reads it rather than the whole tree.
    let contentGeneration: Int
    /// Programmatic scroll target, or `nil` for none. See `MacScoreScrollRequest`.
    let scrollRequest: MacScoreScrollRequest?
    /// Live viewport mirroring for a container that draws an overlay outside this scroll view, or `nil` for one that
    /// does not. See `MacScoreViewportState` — passing `nil` registers no observers and no KVO.
    var viewportState: MacScoreViewportState?
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
        // The desk is painted once, by `MacPagedScoreContainer` behind this host (`MacReaderGround.desk`). Drawing a
        // second one here is exactly the two-sources-of-truth problem that put a dark slab behind the spinner before;
        // the individual page cards paint their own paper white, which is a different thing — that white is the
        // sheet, not the desk.
        scrollView.drawsBackground = false

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        scrollView.magnification = magnification
        context.coordinator.lastGeneration = contentGeneration
        context.coordinator.viewportState = viewportState

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
        // Only a container that asked for the live viewport pays for tracking it. `NSClipView` posts bounds changes at
        // scroll frame rate, and every one of them writes an observable — a cost Page and Vertical have no use for.
        if viewportState != nil {
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView,
            )
        }
        // No seeding write here on purpose: `makeNSView` runs inside a SwiftUI update pass, and `MacScoreViewportState`
        // already starts at the origin and unit magnification — which is exactly where a freshly made scroll view is.

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.binding = $magnification
        coordinator.viewportState = viewportState
        if coordinator.lastGeneration != contentGeneration {
            coordinator.lastGeneration = contentGeneration
            (nsView.documentView as? NSHostingView<Content>)?.rootView = content()
        }
        // **Everything below moves the scroll view from inside a SwiftUI update pass, and moving it posts a bounds
        // change.** With a `viewportState` attached that notification would write an observable in the same pass that
        // is currently rendering — the `NavigationRequestObserver tried to update multiple times per frame` fault
        // `MacScrollViewAppearanceProbe` documents, which was measured in this very screen. The flag makes the
        // coordinator defer exactly the writes this pass causes, and only those: a user's own scroll arrives outside
        // any pass and is still mirrored synchronously, which is what keeps the sticky pane glued to the score.
        coordinator.isApplyingUpdate = true
        defer { coordinator.isApplyingUpdate = false }

        // Apply external magnification writes. Skipped mid-pinch: writing back during a live gesture fights AppKit's
        // own update and reads as the zoom snapping backwards under the fingers.
        if !coordinator.isLiveMagnifying,
           abs(nsView.magnification - magnification) > 0.001
        {
            nsView.magnification = magnification
        }
        if let request = scrollRequest, coordinator.lastScrollToken != request.token {
            coordinator.lastScrollToken = request.token
            switch request.target {
            case let .visible(rect):
                nsView.documentView?.scrollToVisible(rect)
            case let .origin(point):
                animate(nsView, to: point)
            }
        }
    }

    /// Ease the clip view to `point`. Animated rather than snapped for the reason the iOS containers animate their
    /// follow: a cursor that jumps the score sideways every few beats is harder to read than one that slides it.
    private func animate(_ scrollView: NSScrollView, to point: CGPoint) {
        let clipView = scrollView.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(point)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    func makeCoordinator() -> MagnifyingScoreScrollCoordinator {
        MagnifyingScoreScrollCoordinator()
    }
}

/// `MagnifyingScoreScrollView`'s coordinator, deliberately OUTSIDE the generic struct.
///
/// Nesting it would make it generic over `Content` too, and the KVO closure below would then capture that metatype —
/// which the compiler flags as a non-Sendable capture in an isolated closure. Nothing in here needs the content type,
/// so hoisting it is both the fix and the honest shape.
///
/// `@MainActor` because every notification here is posted by AppKit on the main thread and the handlers touch SwiftUI
/// state.
@MainActor
final class MagnifyingScoreScrollCoordinator: NSObject {
    var binding: Binding<CGFloat>?
    var viewportState: MacScoreViewportState?
    var lastGeneration = -1
    var lastScrollToken = -1
    var isLiveMagnifying = false
    /// True only while `updateNSView` is moving the scroll view itself. See the comment at that call site.
    var isApplyingUpdate = false
    /// KVO on `NSScrollView.magnification`, live only between will-start and did-end live magnification. AppKit
    /// posts no "during live magnify" notification, so observing the property is the only continuous signal — and
    /// the sticky pane's `scaleEffect` has to track the pinch or it visibly detaches from the staves mid-gesture.
    /// Installed only for a container that asked for `viewportState`.
    private var magnificationObservation: NSKeyValueObservation?

    @objc func willStartLiveMagnify(_ notification: Notification) {
        isLiveMagnifying = true
        guard viewportState != nil, let scrollView = notification.object as? NSScrollView else { return }
        magnificationObservation = scrollView.observe(\.magnification, options: [.new]) { [weak self] _, change in
            guard let self, let value = change.newValue else { return }
            MainActor.assumeIsolated {
                self.viewportState?.magnification = value
            }
        }
    }

    @objc func magnificationDidEnd(_ notification: Notification) {
        isLiveMagnifying = false
        magnificationObservation = nil
        guard let scrollView = notification.object as? NSScrollView else { return }
        binding?.wrappedValue = scrollView.magnification
        // Catch-up for a final bounds frame that landed on the gesture-end boundary.
        publish(clipView: scrollView.contentView, magnification: scrollView.magnification)
    }

    @objc func boundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else { return }
        publish(clipView: clipView, magnification: clipView.enclosingScrollView?.magnification)
    }

    /// Mirror the clip view's origin (and, when known, the magnification) into the viewport observable — deferred
    /// to the next main-queue callout when a SwiftUI update pass is what moved the scroll view.
    func publish(clipView: NSClipView, magnification: CGFloat?) {
        let origin = clipView.bounds.origin
        guard !isApplyingUpdate else {
            DispatchQueue.main.async { [weak self] in
                self?.write(scroll: origin, magnification: magnification)
            }
            return
        }
        write(scroll: origin, magnification: magnification)
    }

    private func write(scroll: CGPoint, magnification: CGFloat?) {
        guard let viewportState else { return }
        viewportState.scroll = scroll
        if let magnification {
            viewportState.magnification = magnification
        }
    }
}
#endif

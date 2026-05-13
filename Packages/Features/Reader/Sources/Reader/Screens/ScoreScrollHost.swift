import SwiftUI
import UIKit

/// Programmatic scroll target for `ScoreScrollHost`. Producers set the
/// binding; the host applies the offset on the next view update and the
/// command clears itself so the same target isn't re-applied.
enum ScoreScrollCommand: Equatable {
    case immediate(CGPoint)
    case animated(CGPoint)

    var point: CGPoint {
        switch self {
        case let .immediate(point), let .animated(point):
            point
        }
    }

    var isAnimated: Bool {
        if case .animated = self { return true }
        return false
    }
}

/// `UIScrollView`-backed host for the score canvas. We keep `UIScrollView`
/// purely for **pan + gesture coordination** — the built-in zoom is disabled
/// (`maximumZoomScale = 1`) so the score never gets bitmap-upscaled by a
/// `CALayer` transform on `viewForZooming`. Pinch is captured by a custom
/// `UIPinchGestureRecognizer` and fed back into the SwiftUI `scaleEffect`
/// pipeline owned by `VerticalScoreContainer`. That way the pinch behaviour
/// matches Files / Preview (1-finger pan promotes smoothly to pinch when a
/// second finger arrives, and pan-during-pinch works) while pixel sharpness
/// matches the existing SwiftUI `Canvas` re-rasterisation under
/// `scaleEffect`.
struct ScoreScrollHost<Content: View>: UIViewRepresentable {
    @Binding var contentOffset: CGPoint
    @Binding var contentInsetTop: CGFloat
    @Binding var pendingScroll: ScoreScrollCommand?
    /// Which axis bounces back when scrolled past the content edge.
    /// `VerticalScoreContainer` sets `alwaysBounceVertical`;
    /// `HorizontalScoreContainer` sets `alwaysBounceHorizontal`. The
    /// non-bouncing axis still scrolls when content exceeds the viewport
    /// — bouncing is purely a rubber-band-at-edge cue.
    let alwaysBounceVertical: Bool
    let alwaysBounceHorizontal: Bool
    /// Called once when a pinch begins. `anchor` is the gesture centroid
    /// expressed as a `UnitPoint` in the hosted content's coordinate space
    /// (suitable for passing to `scaleEffect(_:anchor:)`). `location` is
    /// the same point in pixels (used later for the commit math).
    let onPinchBegan: (UnitPoint, CGPoint) -> Void
    /// Called every time the pinch's scale factor changes. `scale` goes
    /// to `pinch.magnification`; `translation` is the 2-finger centroid's
    /// displacement (in scroll-view coords) since `.began`. Consumers feed
    /// it into a live offset on whichever axis has no scrollable extent
    /// at the current zoom (vertical mode → x at user-zoom 1.0; horizontal
    /// mode → y at user-zoom 1.0). The axis that `UIScrollView` can scroll
    /// natively is fed back through `contentOffset`; consumers should
    /// discard the matching component of `translation` to avoid
    /// double-counting pan-during-pinch.
    let onPinchChanged: (_ scale: CGFloat, _ translation: CGPoint) -> Void
    /// Called when the pinch ends or is cancelled. Receives the final
    /// magnification, the location captured at `.began` (in host coords),
    /// and the scroll view's contentOffset at the moment of release —
    /// `VerticalScoreContainer` uses these to compute the post-commit
    /// scroll target and the new `viewportZoom`.
    let onPinchEnded: (CGFloat, CGPoint, CGPoint) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        // Disable built-in zoom — we drive scaling via the SwiftUI side.
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.bouncesZoom = false
        scroll.alwaysBounceVertical = alwaysBounceVertical
        scroll.alwaysBounceHorizontal = alwaysBounceHorizontal
        // Forward touches to the SwiftUI gesture stack without the default
        // ~150ms delay. Tap-to-seek + double-tap-to-zoom feel sluggish if
        // we leave delaysContentTouches at its default (true).
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        // SwiftUI side owns the top inset via `.safeAreaPadding` on the
        // host view. `.always` would double-apply and leave margins
        // above / below the score.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator

        let host = UIHostingController(rootView: content())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        // Drive contentSize from SwiftUI's intrinsic size — i.e. the
        // `.frame(framedWidth, framedHeight)` inside zoomedSurface.
        host.sizingOptions = .intrinsicContentSize
        // Stop UIHostingController from inflating intrinsicContentSize
        // by the parent UIScrollView's safe-area insets. Without this,
        // `hostView.bounds` ends up `framedHeight + topInset +
        // bottomInset` tall, and the pinch commit math (which uses
        // `gr.location(in: hostView)` as the anchor) drifts by
        // `topInset * (ratio - 1)` on every zoom commit. `.ignoresSafeArea()`
        // on the SwiftUI side only applies to the representable's own
        // boundary — the embedded host needs its own opt-out.
        host.safeAreaRegions = []
        scroll.addSubview(host.view)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:)),
        )
        pinch.delegate = context.coordinator
        scroll.addGestureRecognizer(pinch)

        context.coordinator.host = host
        context.coordinator.scrollView = scroll
        context.coordinator.pinch = pinch
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // Refresh the parent reference so closures fire with the latest
        // bindings. SwiftUI re-creates the struct each pass; the
        // Coordinator keeps a copy and uses it from delegate methods.
        context.coordinator.parent = self
        // Animation transactions from outer `withAnimation { … }`
        // calls do not reliably reach the hosted SwiftUI subtree via
        // this `rootView` reassignment — UIHostingController treats
        // each assignment as a fresh tree with no transaction. The
        // primary fix lives in the containers: they drive pinch
        // state through an `@Observable` (`PinchState`) so SwiftUI's
        // observation system delivers animated updates straight to
        // the hosted view. The `withTransaction(context.transaction)`
        // wrapper here is belt-and-suspenders for cases where the
        // parent's body *does* re-render (e.g. `pendingScroll`
        // changes) and would otherwise interrupt an in-flight
        // animation with an un-animated rootView replacement.
        withTransaction(context.transaction) {
            context.coordinator.host?.rootView = content()
        }

        if let command = pendingScroll {
            // Force the just-assigned `rootView`'s intrinsic content
            // size to flow into `UIScrollView.contentSize` *before* we
            // set the offset. Otherwise a pinch-end commit applied in
            // the same SwiftUI transaction as a `viewportZoom` increase
            // would clamp to the old `maxScroll`, leaving the pinch
            // anchor visibly drifted by ~`(framedSize_post -
            // framedSize_pre)/2` for one frame.
            uiView.layoutIfNeeded()
            // Apply offset synchronously so the new offset paints in
            // the same frame as the new `viewportZoom`. The flag
            // suppresses the resulting `scrollViewDidScroll` from
            // mutating `parent.contentOffset` mid-update (which would
            // trigger the "Modifying state during view update" warning).
            context.coordinator.isApplyingProgrammaticScroll = true
            uiView.setContentOffset(command.point, animated: command.isAnimated)
            context.coordinator.isApplyingProgrammaticScroll = false
            // Clear the binding on the next runloop tick — mutating it
            // here would still warn.
            let bindingClear = $pendingScroll
            DispatchQueue.main.async {
                if bindingClear.wrappedValue == command {
                    bindingClear.wrappedValue = nil
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ScoreScrollHost
        // Strong ref — UIHostingController is not retained by its view,
        // so without this it deallocates the moment makeUIView returns.
        var host: UIHostingController<Content>?
        weak var scrollView: UIScrollView?
        weak var pinch: UIPinchGestureRecognizer?
        /// Set by `updateUIView` while applying a `pendingScroll`
        /// command synchronously, so `scrollViewDidScroll`'s binding
        /// write-back doesn't fire during a SwiftUI view update.
        var isApplyingProgrammaticScroll = false
        private var pinchStartLocation: CGPoint = .zero
        /// Pinch centroid captured at `.began` in scroll-view coords.
        /// Subtracted from the current centroid each `.changed` tick to
        /// yield pure finger-translation (scrollView coords don't shift
        /// with `contentOffset`, unlike `hostView` coords).
        private var pinchStartCentroid: CGPoint = .zero

        init(parent: ScoreScrollHost) {
            self.parent = parent
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingProgrammaticScroll else { return }
            let offset = scrollView.contentOffset
            if parent.contentOffset != offset {
                parent.contentOffset = offset
            }
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            let top = scrollView.adjustedContentInset.top
            if parent.contentInsetTop != top {
                parent.contentInsetTop = top
            }
        }

        // MARK: UIGestureRecognizerDelegate

        // Critical: lets our pinch fire alongside UIScrollView's built-in
        // pan recognizer, which is the whole reason 1-finger → 2-finger
        // promotion (and pan-during-pinch) works.
        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
        ) -> Bool {
            true
        }

        // MARK: Pinch handler

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            guard let hostView = host?.view else { return }

            switch gr.state {
            case .began:
                pinchStartLocation = gr.location(in: hostView)
                pinchStartCentroid = scrollView.map { gr.location(in: $0) } ?? .zero
                let bounds = hostView.bounds
                let anchor = UnitPoint(
                    x: bounds.width > 0 ? pinchStartLocation.x / bounds.width : 0.5,
                    y: bounds.height > 0 ? pinchStartLocation.y / bounds.height : 0.5,
                )
                parent.onPinchBegan(anchor, pinchStartLocation)
            case .changed:
                let translation = scrollView.map { sv -> CGPoint in
                    let loc = gr.location(in: sv)
                    return CGPoint(
                        x: loc.x - pinchStartCentroid.x,
                        y: loc.y - pinchStartCentroid.y,
                    )
                } ?? .zero
                parent.onPinchChanged(gr.scale, translation)
            case .ended, .cancelled, .failed:
                let currentOffset = scrollView?.contentOffset ?? .zero
                parent.onPinchEnded(gr.scale, pinchStartLocation, currentOffset)
                gr.scale = 1.0
            case .possible:
                break
            @unknown default:
                break
            }
        }
    }
}

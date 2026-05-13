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
    /// Center the hosted content on each axis via `UIScrollView`
    /// `contentInset` when the intrinsic content size is smaller than
    /// the scroll view's bounds on that axis. Horizontal mode opts in
    /// for vertical centering (a single-row score is shorter than the
    /// viewport); vertical mode leaves both false. We can't do this
    /// via SwiftUI `.frame(max(content, viewport), alignment: .center)`
    /// because that inflates `hostView.bounds` past the content's
    /// real bounds, which then desynchronizes the pinch anchor — the
    /// recognizer reports finger locations in `hostView` (= inflated)
    /// space, but the inner `scaleEffect`'s anchor is interpreted
    /// against the underlying view's bounds (= un-inflated). Empty
    /// centering padding makes the two diverge and the pinch pivots
    /// around the wrong content point.
    let centerVertically: Bool
    let centerHorizontally: Bool
    /// Container-provided closure that returns the *expected*
    /// content size for the current state. We can't reliably read
    /// `UIHostingController.view.intrinsicContentSize` inside
    /// `updateUIView`: SwiftUI's re-render of a freshly-assigned
    /// `rootView` is deferred to the next runloop tick, so
    /// `intrinsicContentSize` (and therefore `UIScrollView`
    /// `contentSize`) is still the old value here, and a centering
    /// `contentInset` derived from it would be stale until a later
    /// pass — `setContentOffset` then clamps against the wrong range.
    /// The container already knows the post-zoom framed size from
    /// `viewportZoom` and the document, so it passes a closure that
    /// reads those values on demand. The closure is created in the
    /// container body but its property reads happen at call time
    /// (inside `updateUIView`), so it doesn't register observation
    /// and doesn't force a container re-render on
    /// `viewportZoom` changes.
    let expectedContentSize: () -> CGSize
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

        // Drive UIScrollView's contentInset off the actual host
        // bounds. layoutIfNeeded() flushes pending Auto Layout passes
        // so the intrinsicContentSize from the just-assigned rootView
        // is in place. When the content is smaller than the scroll
        // bounds on a centering axis, split the gap evenly into top/
        // bottom (or left/right) insets so UIScrollView centers the
        // content for us — without inflating `hostView.bounds`, which
        // would break the pinch anchor unit-point calculation.
        uiView.layoutIfNeeded()
        // Use the container's expected content size, not the host's
        // `intrinsicContentSize` (which can be stale until the next
        // SwiftUI render cycle).
        let contentSize = expectedContentSize()
        let scrollBounds = uiView.bounds.size
        let vGap = centerVertically ? max(0, (scrollBounds.height - contentSize.height) / 2) : 0
        let hGap = centerHorizontally ? max(0, (scrollBounds.width - contentSize.width) / 2) : 0
        let newInset = UIEdgeInsets(top: vGap, left: hGap, bottom: vGap, right: hGap)
        if uiView.contentInset != newInset {
            print(
                "[pinch] updateUIView contentInset \(uiView.contentInset) -> \(newInset) " +
                    "scrollBounds=\(scrollBounds) expectedContent=\(contentSize) " +
                    "hostIntrinsic=\(context.coordinator.host?.view.intrinsicContentSize ?? .zero)",
            )
            uiView.contentInset = newInset
        }
        // Force UIScrollView to layout with the new inset so the
        // valid contentOffset range below reflects it.
        uiView.layoutIfNeeded()

        if let command = pendingScroll {
            // Force the just-assigned `rootView`'s intrinsic content
            // size to flow into `UIScrollView.contentSize` *before* we
            // set the offset. Otherwise a pinch-end commit applied in
            // the same SwiftUI transaction as a `viewportZoom` increase
            // would clamp to the old `maxScroll`, leaving the pinch
            // anchor visibly drifted by ~`(framedSize_post -
            // framedSize_pre)/2` for one frame.
            uiView.layoutIfNeeded()
            // Pre-clamp the requested offset into UIScrollView's
            // actual valid range. With `contentInset` providing the
            // vertical centering, the valid `contentOffset.y` range
            // is `[-inset.top, contentSize.height + inset.bottom -
            // bounds.height]` — narrow (often a single point) when
            // the content fits the viewport. Passing an out-of-range
            // value to `setContentOffset(_:animated:false)` makes
            // `bounds.origin` accept it instantaneously and UIScroll
            // View re-clamps on the next layout pass; the transient
            // frame paints the content at the wrong scroll position
            // (visible as a brief "上にずれる" before the clamp lands).
            // Clamping here keeps the offset in range from the start.
            let inset = uiView.contentInset
            // Use the container's expected content size for clamping
            // — `uiView.contentSize` lags one render cycle behind
            // SwiftUI for the same reason `intrinsicContentSize`
            // does (the new rootView's layout hasn't propagated yet),
            // and clamping against the stale size would still land
            // outside UIScrollView's eventually-valid range.
            let size = expectedContentSize()
            let bounds = uiView.bounds
            let minX = -inset.left
            let maxX = max(minX, size.width + inset.right - bounds.width)
            let minY = -inset.top
            let maxY = max(minY, size.height + inset.bottom - bounds.height)
            let clampedPoint = CGPoint(
                x: max(minX, min(maxX, command.point.x)),
                y: max(minY, min(maxY, command.point.y)),
            )
            print(
                "[pinch] setContentOffset target=\(command.point) " +
                    "clampedTo=\(clampedPoint) " +
                    "xRange=[\(minX),\(maxX)] yRange=[\(minY),\(maxY)] " +
                    "expectedSize=\(size) actualSize=\(uiView.contentSize) " +
                    "bounds=\(bounds.size) inset=\(inset)",
            )
            // Apply offset synchronously so the new offset paints in
            // the same frame as the new `viewportZoom`. The flag
            // suppresses the resulting `scrollViewDidScroll` from
            // mutating `parent.contentOffset` mid-update (which would
            // trigger the "Modifying state during view update" warning).
            context.coordinator.isApplyingProgrammaticScroll = true
            uiView.setContentOffset(clampedPoint, animated: command.isAnimated)
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
                let rawLoc = gr.location(in: hostView)
                pinchStartCentroid = scrollView.map { gr.location(in: $0) } ?? .zero
                let bounds = hostView.bounds
                let rawX = bounds.width > 0 ? rawLoc.x / bounds.width : 0.5
                let rawY = bounds.height > 0 ? rawLoc.y / bounds.height : 0.5
                // When the finger lands outside the host's bounds
                // (e.g. in horizontal mode's centering inset area —
                // the host is the framed score, `contentInset` pads
                // the empty space above/below), the raw unit point
                // falls outside [0,1]. `scaleEffect`'s anchor would
                // then pivot around a point in empty space and the
                // visible content would shift away from the
                // natural-rest position during the pinch — at
                // release, snapping back to a topLeading-anchored
                // composition reads as a sudden jump (the original
                // "上にずれる" symptom).
                //
                // Fall back to `.center` on any out-of-range axis so
                // the gesture pivots at the score center for both
                // the live scaleEffect and the commit math
                // (`pinchStartLocation` is moved to the clamped
                // anchor too). Pre-release and post-release both
                // sit centered, so no jump.
                let clampedX = (0 ... 1).contains(rawX) ? rawX : 0.5
                let clampedY = (0 ... 1).contains(rawY) ? rawY : 0.5
                pinchStartLocation = CGPoint(
                    x: clampedX * bounds.width,
                    y: clampedY * bounds.height,
                )
                let anchor = UnitPoint(x: clampedX, y: clampedY)
                print(
                    "[pinch] began host.bounds=\(bounds.size) intrinsic=\(hostView.intrinsicContentSize) " +
                        "scroll.bounds=\(scrollView?.bounds.size ?? .zero) " +
                        "scroll.contentInset=\(scrollView?.contentInset ?? .zero) " +
                        "scroll.contentOffset=\(scrollView?.contentOffset ?? .zero) " +
                        "rawLoc=\(rawLoc) raw=(\(rawX),\(rawY)) " +
                        "startLoc=\(pinchStartLocation) anchor=\(anchor)",
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
                print(
                    "[pinch] ended scale=\(gr.scale) " +
                        "host.bounds=\(hostView.bounds.size) intrinsic=\(hostView.intrinsicContentSize) " +
                        "scroll.bounds=\(scrollView?.bounds.size ?? .zero) " +
                        "scroll.contentInset=\(scrollView?.contentInset ?? .zero) " +
                        "currentOffset=\(currentOffset) startLoc=\(pinchStartLocation)",
                )
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

import SwiftUI

/// Base zoom captured at a vertical pinch's `.began`, so the commit math resolves against the gesture's starting scale.
/// Shared by the score and PDF vertical readers — both host `VerticalReaderShell`.
struct VerticalPinchSession {
    var baseZoom: CGFloat
}

/// The shared scroll + pinch shell for the vertical readers (score + PDF). Hosts `content` inside a `ScoreScrollHost`
/// and owns the vertical pinch-commit orchestration (via `ReaderPinchCommit`), so both vertical readers share one
/// gesture / zoom / annotation pipeline. The shell applies NO committed-zoom `scaleEffect` itself — the hosted
/// `content` composes committed zoom (as `VerticalZoomedSurface` and the PDF page stack do).
///
/// `committedZoom`, `pinchSession`, `liveScrollOffset`, etc. stay as `@State` on the CONTAINER and are passed in as
/// bindings so the existing observation + animation behavior is preserved exactly. The container also keeps its
/// content-specific plumbing (score: layout rebuild / autoscroll / annotation reproject; PDF: page geometry).
struct VerticalReaderShell<Content: View>: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    /// Current viewport size. Only `width` is read — by the commit's `scrollAbsorbsOffset` check.
    let viewport: CGSize
    @Binding var liveScrollOffset: CGPoint
    @Binding var contentInsetTop: CGFloat
    @Binding var pendingScroll: ScoreScrollCommand?
    @Binding var committedZoom: CGFloat
    @Binding var pinchSession: VerticalPinchSession?
    /// Post-zoom framed content size for the current state. Read at call time by the host (see `ScoreScrollHost`).
    let expectedContentSize: () -> CGSize
    /// Opt-in annotation overlay. Its `state` closure reads live `pinch.*` at call time, so a value captured at the
    /// container's last render stays correct while the shell re-renders during a pinch.
    let annotationOverlay: AnnotationOverlaySpec?
    /// The content-space document width for the commit's `scrollAbsorbsOffset` check — `document?.size.width` for the
    /// score, the fitted page width for PDF. Supplied by the content so the shell stays content-agnostic.
    let onPinchCommitDocWidth: () -> CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Observe the live pinch magnification here so the shell re-renders each frame of a commit reset animation;
        // that re-runs the host's annotation-canvas sync, so the ink eases in lockstep with the content.
        _ = pinch.magnification
        return ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: true,
            alwaysBounceHorizontal: false,
            centerVertically: false,
            centerHorizontally: false,
            expectedContentSize: expectedContentSize,
            onPinchBegan: { anchor, _ in
                pinch.cancelResetAnimation() // don't let a trailing commit ease fight the new gesture
                pinchSession = VerticalPinchSession(baseZoom: viewModel.viewportZoom)
                pinch.anchor = anchor
                pinch.magnification = 1.0
                pinch.offsetX = 0
            },
            onPinchChanged: { magnification, translation in
                // Y is fed back through `UIScrollView.contentOffset` natively; only X needs a live offset (no
                // horizontal scrollable extent at user-zoom 1.0).
                pinch.magnification = magnification
                pinch.offsetX = translation.x
            },
            onPinchEnded: { magnification, startLocation, currentOffset in
                commitPinch(magnification: magnification, startLocation: startLocation, currentOffset: currentOffset)
            },
            annotationOverlay: annotationOverlay,
            content: content,
        )
        // `UIViewRepresentable` resolves safe area by shrinking its UIView frame — can't surface it as `contentInsets`
        // the way SwiftUI's own `ScrollView` does. Overlays sit on top in a ZStack, so the content sliding under
        // them is intentional.
        .ignoresSafeArea()
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll so the content under the user's fingers at
    /// release lands on the same screen position post-commit. This is the vertical commit orchestration moved
    /// verbatim from `VerticalScoreContainer` (now shared with the PDF vertical reader). Vertical pan-during-pinch
    /// rides on
    /// `currentOffset` (UIScrollView native); horizontal rides on `pinch.offsetX`.
    private func commitPinch(magnification: CGFloat, startLocation: CGPoint, currentOffset: CGPoint) {
        let session = pinchSession ?? VerticalPinchSession(baseZoom: viewModel.viewportZoom)
        pinchSession = nil

        let r = ReaderPinchCommit.resolve(PinchCommitInput(
            baseZoom: session.baseZoom, magnification: magnification,
            startLocation: startLocation, currentOffset: currentOffset,
            offsetX: pinch.offsetX, offsetY: 0,
        ))
        let scrollToTarget = CGPoint(x: max(0, r.rawScrollTarget.x), y: max(0, r.rawScrollTarget.y))

        if r.isBounceBack {
            // Rubber-band release from baseline 1.0. `pinch.anchor` is intentionally left at the gesture's start anchor
            // — animating it toward `.center` would interpolate the scale pivot and read as judder. The reset eases
            // frame-by-frame (PinchState.animateReset) so the annotation ink overlay follows it in lockstep.
            pinch.animateReset(toMagnification: 1.0, offsetX: 0)
        } else {
            committedZoom = r.targetZoom
            pendingScroll = .immediate(scrollToTarget)
            if r.snapToUnit {
                // Snap-to-unit from a non-unit base. Set the post-commit `viewportZoom` and compensate magnification so
                // the visible scale (viewportZoom × magnification) is invariant at the commit instant, then ease
                // magnification → 1.0 frame-by-frame so visible scale moves monotonically `combined → 1.0`.
                viewModel.resetZoom()
                pinch.magnification = r.compensatedMag
                pinch.animateReset(toMagnification: 1.0, offsetX: 0)
            } else {
                // Real zoom-in / zoom-out. Combined visible scale is invariant across the commit
                // (`baseZoom × gr.scale = targetZoom × 1.0`); interpolating each factor separately would bulge along
                // the easing curve and read as an unwanted scale animation. Snap the scale state, animate only the live
                // offset reset, and only when the scroll view can't absorb it.
                viewModel.viewportZoom = r.targetZoom
                pinch.magnification = 1.0
                pinch.anchor = .center

                let docWidth = onPinchCommitDocWidth()
                let postFramedWidth = min(docWidth, viewport.width) * r.targetZoom
                let scrollAbsorbsOffset = postFramedWidth > viewport.width
                if pinch.offsetX != 0, !scrollAbsorbsOffset {
                    pinch.animateReset(toMagnification: pinch.magnification, offsetX: 0)
                } else {
                    pinch.offsetX = 0
                }
            }
        }
    }
}

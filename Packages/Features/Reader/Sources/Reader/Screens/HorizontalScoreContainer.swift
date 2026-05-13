// swiftlint:disable file_length
// (temporary; remove with the pinch instrumentation prints below)
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a `ScoreScrollHost` (UIKit-backed)
/// and lays the score out at its natural width — no system wrapping.
/// The user scrolls one long row of measures; pinch / double-tap zoom
/// follow the same scaleEffect composition as `VerticalScoreContainer`.
///
/// Pinch composition (identical to vertical, axes swapped):
///   * inner `pinch.magnification` with `anchor: pinch.anchor` — pivots
///     the visual around the user's fingers without changing layout;
///   * outer committed `viewportZoom` with `anchor: .topLeading` — the
///     persistent scale that drives the `.frame` size and the scroll
///     view's scrollable extent.
///
/// During a live pinch, X pan-during-pinch rides on `currentOffset`
/// (UIScrollView native, since horizontal mode always has horizontal
/// extent); Y pan-during-pinch rides on `pinch.offsetY` (mirror of
/// vertical mode's `pinch.offsetX`).
struct HorizontalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    /// Held in `@State` so the same `@Observable` instance lives for
    /// the view's lifetime. The container's body never reads
    /// `pinch.*` directly — only the hosted `HorizontalZoomedSurface`
    /// does — so mutations propagate via observation into the host
    /// without retriggering the parent's body (and thus avoid a
    /// `rootView` reassignment that would drop the animation
    /// transaction).
    @State private var pinch = PinchState()
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE any
    /// `withAnimation` block so it reflects the final committed
    /// value immediately. Reads of `viewModel.viewportZoom` inside a
    /// closure called during an in-flight animation appear to return
    /// the interpolated (not final) value — so the `expectedContent
    /// Size` closure passed to `ScoreScrollHost` reads this instead,
    /// keeping the centering `contentInset` and `setContentOffset`
    /// clamp ranges anchored to the post-commit framed size from the
    /// first render pass.
    @State private var committedZoom: CGFloat = 1.0

    private let scorePadding: CGFloat = 16

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            scrollContent(viewport: proxy.size)
                .task(id: TaskKey(
                    score: score, size: staffSize,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                )) {
                    await rebuildLayout()
                }
        }
    }

    private func scrollContent(viewport: CGSize) -> some View {
        ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: false,
            alwaysBounceHorizontal: true,
            centerVertically: true,
            centerHorizontally: false,
            expectedContentSize: {
                // Read `committedZoom` (the final target) rather than
                // `viewModel.viewportZoom` — the latter returns
                // interpolated values while a SwiftUI animation is
                // in flight, which makes the centering inset and
                // scroll clamp jump in two passes (first with the
                // pre-commit value, then with the post-commit value).
                let doc = document?.size ?? .zero
                let zoom = committedZoom
                return CGSize(
                    width: (doc.width + scorePadding * 2) * zoom,
                    height: (doc.height + scorePadding * 2) * zoom,
                )
            },
            onPinchBegan: { anchor, _ in
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
                pinch.anchor = anchor
                pinch.magnification = 1.0
                pinch.offsetY = 0
            },
            onPinchChanged: { magnification, translation in
                // X is fed back through `UIScrollView.contentOffset`
                // natively (horizontal extent always exists in this
                // mode); only Y needs a live offset.
                pinch.magnification = magnification
                pinch.offsetY = translation.y
            },
            onPinchEnded: { magnification, startLocation, currentOffset in
                commitPinch(
                    magnification: magnification,
                    startLocation: startLocation,
                    currentOffset: currentOffset,
                    viewport: viewport,
                )
            },
        ) {
            HorizontalZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                score: score,
                viewport: viewport,
                scorePadding: scorePadding,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
                onDoubleTap: { viewModel.toggleZoom(targetIfZoomedOut: 2.0) },
            )
        }
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll
    /// so the content under the user's fingers at release lands on
    /// the same screen position post-commit. Horizontal
    /// pan-during-pinch rides on `currentOffset` (UIScrollView
    /// native); vertical rides on `pinch.offsetY`.
    ///
    /// `newOffset = startLocation * (ratio - 1) + currentOffset − (0, pinch.offsetY)`
    private func commitPinch(
        magnification: CGFloat,
        startLocation: CGPoint,
        currentOffset: CGPoint,
        viewport: CGSize,
    ) {
        let session = pinchSession ?? PinchSession(baseZoom: viewModel.viewportZoom)
        pinchSession = nil

        let combined = session.baseZoom * magnification
        let targetZoom: CGFloat = combined < 1.05 ? 1.0 : combined
        let ratio = targetZoom / session.baseZoom

        // Pre-compute the post-commit contentInset.top so we can clamp
        // `scrollToTarget.y` against the actual valid contentOffset
        // range. `ScoreScrollHost` will set the same value in
        // `updateUIView` once the new framed size flows through Auto
        // Layout. Without this, the formula's natural Y target (e.g.
        // -117 when valid range is [-116, -116]) gets clamped against
        // the wrong floor (`max(0, …)` was correct for the no-inset
        // era but bumps the target to 0 here, which UIScrollView then
        // re-clamps to -116 on the next layout pass — visible as a
        // one-frame upward jump to viewport top before settling).
        let docH = document?.size.height ?? 0
        let preFramedH = (docH + scorePadding * 2) * session.baseZoom
        let postFramedH = (docH + scorePadding * 2) * targetZoom
        let postInsetTop = max(0, (viewport.height - postFramedH) / 2)

        let scrollToTarget = CGPoint(
            x: max(0, currentOffset.x + startLocation.x * (ratio - 1)),
            y: max(-postInsetTop, currentOffset.y + startLocation.y * (ratio - 1) - pinch.offsetY),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        print(
            "[pinch] commit base=\(session.baseZoom) mag=\(magnification) combined=\(combined) " +
                "target=\(targetZoom) ratio=\(ratio) bounce=\(isBounceBack) " +
                "viewport=\(viewport) preFramedH=\(preFramedH) postFramedH=\(postFramedH) " +
                "pinch.anchor=\(pinch.anchor) pinch.magnification=\(pinch.magnification) " +
                "pinch.offsetY=\(pinch.offsetY) currentOffset=\(currentOffset) " +
                "startLocation=\(startLocation) scrollToTarget=\(scrollToTarget)",
        )
        if isBounceBack {
            // Rubber-band release: animate `pinch.magnification` back
            // to identity. See `VerticalScoreContainer.commitPinch`
            // for the rationale on holding `pinch.anchor` steady
            // through the bounce animation.
            // (No `committedZoom` change needed — viewportZoom stays
            // at 1.0 throughout.)
            withAnimation(.smooth(duration: 0.18)) {
                pinch.magnification = 1.0
                pinch.offsetY = 0
            }
        } else {
            // Set `committedZoom` (the closure-readable mirror)
            // outside `withAnimation` so the `expectedContentSize`
            // closure consulted in `ScoreScrollHost.updateUIView`
            // reads the final post-commit value immediately (rather
            // than the interpolated `viewModel.viewportZoom` during
            // the animation).
            committedZoom = targetZoom
            pendingScroll = .immediate(scrollToTarget)
            let snapToUnit = targetZoom <= 1.0
            if snapToUnit {
                // Snap-to-unit from a non-unit base. Naïvely
                // animating both `viewModel.viewportZoom`
                // (`base → target`) and `pinch.magnification`
                // (`gr.scale → 1`) together makes their product bulge
                // mid-animation — for a 3× → 1× zoom-out the combined
                // visible scale overshoots 1.0 by ~30% at the midpoint,
                // which the user sees as a big lateral expansion-then-
                // contraction.
                //
                // Decompose into two phases:
                //
                //   1. *Synchronous snap.* Set the post-commit
                //      `viewportZoom` and compensate magnification
                //      to `combined / targetZoom`. The visible scale
                //      (`viewportZoom × magnification`) is invariant
                //      across this snap.
                //   2. *Animated decay.* In the next runloop tick,
                //      animate magnification → 1.0 (and offset → 0).
                //      Visible scale moves monotonically from
                //      `combined` to 1.0 via a single factor — no
                //      bulge.
                //
                // The async hop is what makes SwiftUI treat the
                // compensated value as the animation's starting
                // point. Inlining both mutations into one `with
                // Animation` call would have SwiftUI animate from
                // `pre-release magnification` to 1.0 directly,
                // re-introducing the bulge.
                let compensatedMag = combined / targetZoom
                viewModel.resetZoom()
                pinch.magnification = compensatedMag
                DispatchQueue.main.async {
                    withAnimation(.smooth(duration: 0.18)) {
                        pinch.magnification = 1.0
                        pinch.offsetY = 0
                    }
                }
            } else {
                // Real zoom-in / zoom-out. The combined visible scale
                // (`viewportZoom × pinch.magnification`) is invariant
                // across the commit: it goes from `baseZoom × gr.scale
                // = combined` to `targetZoom × 1.0 = combined`. But
                // interpolating each factor separately makes their
                // product bulge along the easing curve, which reads as
                // an unwanted scale animation at release. Snap the
                // scale state instead and only animate the live offset
                // reset — and only when the scroll view can't absorb
                // it (`postFramedHeight ≤ viewport.height`, scroll
                // extent zero, `scrollToTarget.y` clamps to 0).
                viewModel.viewportZoom = targetZoom
                viewModel.captureCurrentZoomAsLast()
                pinch.magnification = 1.0
                pinch.anchor = .center

                let docHeight = document?.size.height ?? 0
                let postFramedHeight = (docHeight + scorePadding * 2) * targetZoom
                let scrollAbsorbsOffset = postFramedHeight > viewport.height
                if pinch.offsetY != 0, !scrollAbsorbsOffset {
                    withAnimation(.smooth(duration: 0.18)) {
                        pinch.offsetY = 0
                    }
                } else {
                    pinch.offsetY = 0
                }
            }
        }
    }

    /// Horizontal mode: lay out at natural content width so systems
    /// never wrap. Title frame is omitted — it'd push the score
    /// down inside what is essentially a single long row.
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
        )
    }

    /// Runs `LayoutEngine.layout` off the main actor so a heavy re-layout
    /// (staff hide/show, clef override, staff-size change) doesn't stall
    /// the UI. The `.task(id:)` wrapper cancels the outer task on the next
    /// input change; we honor that here before publishing a stale document.
    private func rebuildLayout() async {
        let score = score
        let opts = scoreOptions
        let newDoc = await Task.detached(priority: .userInitiated) {
            let natural = LayoutEngine.naturalContentWidth(score: score, options: opts)
            return LayoutEngine.layout(score: score, options: opts, availableWidth: natural)
        }.value
        guard !Task.isCancelled else { return }
        document = newDoc
    }

    private func autoScroll(
        cursor: ScoreCursor?,
        viewport: CGSize,
    ) {
        guard let cursor, let doc = document,
              let rect = doc.cursorFrame(for: cursor, in: score)
        else { return }

        let zoom = viewModel.viewportZoom
        let pad = 8 * doc.metrics.sp * zoom

        // Cursor frame in scroll-content coords: padded then scaled
        // from top-leading. Mirrors `HorizontalZoomedSurface`'s
        // composition.
        let minX = (rect.minX + scorePadding) * zoom
        let maxX = (rect.maxX + scorePadding) * zoom
        let minY = (rect.minY + scorePadding) * zoom
        let maxY = (rect.maxY + scorePadding) * zoom

        let curX = liveScrollOffset.x
        let curY = liveScrollOffset.y

        let newX = adjustedScrollOffset(
            currentOffset: curX,
            targetMin: minX, targetMax: maxX,
            viewportSize: viewport.width, pad: pad,
        )
        let newY = adjustedScrollOffset(
            currentOffset: curY,
            targetMin: minY, targetMax: maxY,
            viewportSize: viewport.height, pad: pad,
        )

        if abs(newX - curX) < 0.5, abs(newY - curY) < 0.5 { return }

        pendingScroll = .animated(CGPoint(x: newX, y: newY))
    }

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside
    /// the viewport with `pad` margin. Same shape as
    /// `VerticalScoreContainer.adjustedScrollOffset` — duplicated rather
    /// than shared because the math is short and orientation-agnostic.
    private func adjustedScrollOffset(
        currentOffset cur: CGFloat,
        targetMin: CGFloat,
        targetMax: CGFloat,
        viewportSize: CGFloat,
        pad: CGFloat,
    ) -> CGFloat {
        let viewMin = cur
        let viewMax = cur + viewportSize
        if targetMax - targetMin > viewportSize {
            return max(0, targetMin)
        }
        if targetMin >= viewMin, targetMax <= viewMax {
            return cur
        }
        if targetMin < viewMin {
            return max(0, targetMin - pad)
        }
        return targetMax - viewportSize + pad
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool

        init(
            score: Score,
            size: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
        ) {
            // Structural shape + opening clefs. See
            // `VerticalScoreContainer.TaskKey` for the matching
            // rationale on why opening-clef hash is included.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
            self.size = size
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
        }
    }
}

/// The hosted score subtree. Lives inside `ScoreScrollHost`'s
/// `UIHostingController`. Reads `pinch.*` and `viewModel.viewportZoom`
/// directly so the SwiftUI observation system can deliver animated
/// updates inside the host (the parent `HorizontalScoreContainer` body
/// never touches these properties, so it doesn't re-render and the
/// hostingController doesn't reassign its `rootView` on every gesture
/// frame).
private struct HorizontalZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let scorePadding: CGFloat
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?
    let onDoubleTap: () -> Void

    var body: some View {
        if let doc = document {
            let zoom = viewModel.viewportZoom
            let framedWidth = (doc.size.width + scorePadding * 2) * zoom
            let framedHeight = (doc.size.height + scorePadding * 2) * zoom
            scoreSurface(document: doc)
                .padding(scorePadding)
                .scaleEffect(pinch.magnification, anchor: pinch.anchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: 0, y: pinch.offsetY)
                // Single frame at exactly the framed (zoomed) size.
                // Vertical centering when the score is shorter than
                // the viewport is handled by
                // `UIScrollView.contentInset` in `ScoreScrollHost`
                // (see `centerVertically`) — using a second outer
                // `.frame(max(...), alignment: .leading)` here would
                // inflate `hostView.bounds` and desynchronize the
                // pinch anchor from the inner scaleEffect's view
                // bounds, pivoting the scaling around the wrong
                // content point.
                .frame(
                    width: framedWidth,
                    height: framedHeight,
                    alignment: .topLeading,
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { _ in
                        onDoubleTap()
                    },
                )
        } else {
            Color.clear
        }
    }

    private func scoreSurface(document doc: LayoutDocument) -> some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor,
            )
            .coordinateSpace(name: "scoreSurface")
            .gesture(tapSeekGesture(document: doc))
            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: doc,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }
        }
    }

    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }
}

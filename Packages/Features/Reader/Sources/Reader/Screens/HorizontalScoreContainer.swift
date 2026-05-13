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

        let scrollToTarget = CGPoint(
            x: max(0, currentOffset.x + startLocation.x * (ratio - 1)),
            y: max(0, currentOffset.y + startLocation.y * (ratio - 1) - pinch.offsetY),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        if isBounceBack {
            // Rubber-band release: animate `pinch.magnification` back
            // to identity. See `VerticalScoreContainer.commitPinch`
            // for the rationale on holding `pinch.anchor` steady
            // through the bounce animation.
            withAnimation(.smooth(duration: 0.18)) {
                pinch.magnification = 1.0
                pinch.offsetY = 0
            }
        } else {
            // Animate the commit *only* when the scroll view can't
            // absorb the `pinch.offsetY` compensation on this axis —
            // i.e. when post-commit `framedHeight <= viewport.height`,
            // `scrollToTarget.y` would clamp to 0 via the `max(0, …)`
            // guard and the offset compensation would fail, leaving a
            // visible one-frame jump opposite the pan direction.
            // Animating in that case lets `pinch.offsetY` spring back
            // to 0 over `.smooth(duration: 0.18)` so the content
            // settles to its centered rest position smoothly.
            //
            // When the scroll can absorb (post-commit content taller
            // than viewport), snap everything synchronously so the
            // offset → 0 snap and the corresponding scroll snap
            // cancel out in the same frame — animating here would
            // desynchronize them and cause a wobble.
            let docHeight = document?.size.height ?? 0
            let postFramedHeight = (docHeight + scorePadding * 2) * targetZoom
            let needsAnimation = postFramedHeight <= viewport.height
            pendingScroll = .immediate(scrollToTarget)
            applyCommit(animated: needsAnimation) {
                if targetZoom <= 1.0 {
                    viewModel.resetZoom()
                } else {
                    viewModel.viewportZoom = targetZoom
                    viewModel.captureCurrentZoomAsLast()
                }
                pinch.magnification = 1.0
                pinch.anchor = .center
                pinch.offsetY = 0
            }
        }
    }

    private func applyCommit(animated: Bool, _ body: () -> Void) {
        if animated {
            withAnimation(.smooth(duration: 0.18), body)
        } else {
            body()
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
                // Inner frame at exactly the framed (zoomed) size so
                // the topLeading-anchored outer scaleEffect fills it.
                .frame(
                    width: framedWidth,
                    height: framedHeight,
                    alignment: .topLeading,
                )
                // Outer frame inflates to at least the viewport so a
                // short score is vertically centered (`.leading` =
                // leading-X + center-Y). See HorizontalScoreContainer's
                // top comment for the math.
                .frame(
                    width: max(framedWidth, viewport.width),
                    height: max(framedHeight, viewport.height),
                    alignment: .leading,
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

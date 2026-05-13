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
///   * inner `liveMagnification` with `anchor: liveMagAnchor` (gesture
///     start anchor reported by the host's `UIPinchGestureRecognizer`) —
///     pivots the visual around the user's fingers without changing
///     layout;
///   * outer committed `viewportZoom` with `anchor: .topLeading` — the
///     persistent scale that drives the `.frame` size and the scroll
///     view's scrollable extent.
///
/// During a live pinch, X pan-during-pinch rides on `currentOffset`
/// (UIScrollView native, since horizontal mode always has horizontal
/// extent); Y pan-during-pinch rides on `liveOffsetY` (mirror of
/// vertical mode's `liveOffsetX`).
struct HorizontalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastManualCursor: ScoreCursor?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0

    // Tracked as `@State` (not `@GestureState`) for the same reason
    // vertical does: auto-reset before `onEnded` runs would snap the
    // inner `scaleEffect` back to identity and pull content away from
    // the anchor by `1 - mag`.
    @State private var liveMagnification: CGFloat = 1.0
    @State private var liveMagAnchor: UnitPoint = .center

    /// Pinch-driven vertical offset so pan-during-pinch tracks 1:1
    /// even when `UIScrollView` has no vertical extent (single row of
    /// systems at user-zoom 1.0). Mirror of vertical's `liveOffsetX`.
    @State private var liveOffsetY: CGFloat = 0

    /// Padding inside the scaled content so the first / last measure
    /// don't butt up against the viewport edges. Scales with zoom
    /// because it sits inside the `scaleEffect`.
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
                liveMagAnchor = anchor
                liveMagnification = 1.0
                liveOffsetY = 0
            },
            onPinchChanged: { magnification, translation in
                // X is fed back through `UIScrollView.contentOffset`
                // natively (horizontal extent always exists in this
                // mode); only Y needs a live offset.
                liveMagnification = magnification
                liveOffsetY = translation.y
            },
            onPinchEnded: { magnification, startLocation, currentOffset in
                commitPinch(
                    magnification: magnification,
                    startLocation: startLocation,
                    currentOffset: currentOffset,
                )
            },
        ) {
            zoomedSurface(viewport: viewport)
        }
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
    }

    @ViewBuilder
    private func zoomedSurface(viewport: CGSize) -> some View {
        if let doc = document {
            let zoom = viewModel.viewportZoom
            let framedWidth = (doc.size.width + scorePadding * 2) * zoom
            let framedHeight = (doc.size.height + scorePadding * 2) * zoom
            scoreSurface(document: doc)
                .padding(scorePadding)
                .scaleEffect(liveMagnification, anchor: liveMagAnchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: 0, y: liveOffsetY)
                // Inflate the outer frame to at least the viewport so a
                // score shorter than the viewport gets centered vertically
                // (`.leading` = leading-X + center-Y). Horizontal still
                // pins to leading so the score opens at measure 1, not
                // mid-page. When zoomed in past the viewport on either
                // axis, the `max(...)` collapses to the framed size and
                // normal scrolling resumes.
                .frame(
                    width: max(framedWidth, viewport.width),
                    height: max(framedHeight, viewport.height),
                    alignment: .leading,
                )
                .simultaneousGesture(doubleTapGesture)
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

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                viewModel.toggleZoom(targetIfZoomedOut: 2.0)
            }
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll
    /// so the content under the user's fingers at release lands on the
    /// same screen position post-commit. Horizontal pan-during-pinch
    /// rides on `currentOffset` (UIScrollView native); vertical rides
    /// on `liveOffsetY`.
    ///
    /// `newOffset = startLocation * (ratio - 1) + currentOffset − (0, liveOffsetY)`
    private func commitPinch(
        magnification: CGFloat,
        startLocation: CGPoint,
        currentOffset: CGPoint,
    ) {
        let session = pinchSession ?? PinchSession(baseZoom: viewModel.viewportZoom)
        pinchSession = nil

        let combined = session.baseZoom * magnification
        let targetZoom: CGFloat = combined < 1.05 ? 1.0 : combined
        let ratio = targetZoom / session.baseZoom

        let scrollToTarget = CGPoint(
            x: max(0, currentOffset.x + startLocation.x * (ratio - 1)),
            y: max(0, currentOffset.y + startLocation.y * (ratio - 1) - liveOffsetY),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        if isBounceBack {
            // Rubber-band release: see VerticalScoreContainer.commitPinch
            // for the rationale on holding `liveMagAnchor` steady through
            // the bounce animation.
            withAnimation(.smooth(duration: 0.15)) {
                liveMagnification = 1.0
                liveOffsetY = 0
            }
        } else {
            pendingScroll = .immediate(scrollToTarget)
            if targetZoom <= 1.0 {
                viewModel.resetZoom()
            } else {
                viewModel.viewportZoom = targetZoom
                viewModel.captureCurrentZoomAsLast()
            }
            liveMagnification = 1.0
            liveMagAnchor = .center
            liveOffsetY = 0
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
        // from top-leading. Mirrors `zoomedSurface`'s composition.
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

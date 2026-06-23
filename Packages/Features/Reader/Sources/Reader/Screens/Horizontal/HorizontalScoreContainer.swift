import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Lays the score out at its natural width — no system wrapping — inside a `ScoreScrollHost`. The user scrolls one long
/// row of measures; pinch / double-tap zoom follow the same composition as `VerticalScoreContainer`. See that file's
/// docblock for the pinch / scaleEffect rationale; axes are swapped here (X is the always-scrollable axis).
struct HorizontalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let playbackCursor: ScoreCursor?
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `TaskKey` — the score passed in is
    /// already transposed. Without this the `TaskKey.scoreSignature` hash doesn't change on transpose and the layout
    /// task never re-runs.
    let transposeSemitones: Int
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var pinch = PinchState()
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE any `withAnimation` block so it reflects the final committed
    /// value immediately — the `expectedContentSize` closure reads this to dodge SwiftUI's animated interpolation while
    /// the commit transition is in flight.
    @State private var committedZoom: CGFloat = 1.0

    private let scorePadding: CGFloat = 16

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            scrollContent(viewport: proxy.size)
                .onAppear { eagerLayoutIfNeeded() }
                .task(id: TaskKey(
                    score: score, size: staffSize,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    showInvisibleElements: showInvisibleElements,
                    transposeSemitones: transposeSemitones,
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
                // X is fed back through `UIScrollView.contentOffset` natively (horizontal extent always exists in this
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
            annotationOverlay: nil, // annotation is Vertical-mode only (M1)
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
            )
        }
        // Let the score reach the screen edges and slide under the translucent overlays — the `UIViewRepresentable`'s
        // UIView frame is otherwise shrunk by the system safe area and parent overlay reserve.
        .ignoresSafeArea()
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll so the content under the user's fingers at
    /// release lands on the same screen position post-commit. Horizontal pan-during-pinch rides on `currentOffset`
    /// (UIScrollView native); vertical rides on `pinch.offsetY`. See `VerticalScoreContainer.commitPinch` for the full
    /// rationale on the two-phase snap-to-unit and the scale-state-snap to avoid mid-animation bulge.
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

        // Pre-compute the post-commit contentInset.top so we can clamp `scrollToTarget.y` against the actual valid
        // contentOffset range — UIScrollView would otherwise re-clamp on the next layout pass, visible as a one-frame
        // upward jump.
        let docHeight = document?.size.height ?? 0
        let postFramedH = (docHeight + scorePadding * 2) * targetZoom
        let postInsetTop = max(0, (viewport.height - postFramedH) / 2)

        let scrollToTarget = CGPoint(
            x: max(0, currentOffset.x + startLocation.x * (ratio - 1)),
            y: max(-postInsetTop, currentOffset.y + startLocation.y * (ratio - 1) - pinch.offsetY),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        if isBounceBack {
            withAnimation(.smooth(duration: 0.18)) {
                pinch.magnification = 1.0
                pinch.offsetY = 0
            }
        } else {
            committedZoom = targetZoom
            pendingScroll = .immediate(scrollToTarget)
            let snapToUnit = targetZoom <= 1.0
            if snapToUnit {
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
                viewModel.viewportZoom = targetZoom
                pinch.magnification = 1.0
                pinch.anchor = .center

                let scrollAbsorbsOffset = postFramedH > viewport.height
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

    /// Horizontal mode: lay out at natural content width so systems never wrap. Title frame is omitted — it'd push the
    /// score down inside what is essentially a single long row.
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
            showsInvisibleElements: showInvisibleElements,
        )
    }

    /// SwiftUI `#Preview` snapshots the view tree before the async `.task` (which hops to a detached background
    /// `LayoutEngine.layout`) completes, so `document` is still nil and the score area renders blank. When running
    /// under Xcode Previews, lay the score out synchronously on first appearance so the snapshot has a populated
    /// `document`. No-op in the real app / live capture (those let the async path run and never enter this branch).
    private func eagerLayoutIfNeeded() {
        guard document == nil else { return }
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" else { return }
        let natural = LayoutEngine.naturalContentWidth(score: score, options: scoreOptions)
        document = LayoutEngine.layout(score: score, options: scoreOptions, availableWidth: natural)
    }

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

        // Cursor frame in scroll-content coords: padded then scaled from top-leading. Mirrors
        // `HorizontalZoomedSurface`'s composition. Only Y rides on the cursor frame; X anchors on the whole measure.
        let minY = (rect.minY + scorePadding) * zoom
        let maxY = (rect.maxY + scorePadding) * zoom

        let curX = liveScrollOffset.x
        let curY = liveScrollOffset.y

        // X: when the cursor's measure overflows the viewport, park its leading edge at the screen's left edge rather
        // than nudging minimally to the right edge. Matches the PiP renderer's `advanceScroll`, so both surfaces step
        // measure-by-measure left.
        // Parity: the measure leading-edge anchoring now lives in
        // Domain.horizontalMeasureScrollOffset (also called by the Android Reader).
        let newX: CGFloat = if let measure = measureRect(for: cursor, in: doc) {
            CGFloat(horizontalMeasureScrollOffset(
                current: Double(curX),
                measureMin: Double((measure.minX + scorePadding) * zoom),
                measureMax: Double((measure.maxX + scorePadding) * zoom),
                viewport: Double(viewport.width),
                pad: Double(pad),
            ))
        } else {
            curX
        }
        let newY = adjustedScrollOffset(
            currentOffset: curY,
            targetMin: minY, targetMax: maxY,
            viewportSize: viewport.height, pad: pad,
        )

        if abs(newX - curX) < 0.5, abs(newY - curY) < 0.5 { return }

        pendingScroll = .animated(CGPoint(x: newX, y: newY))
    }

    /// Scroll-content rect of the measure the cursor sits on, regardless of `.item` vs `.beat`. The auto-scroll trigger
    /// is "the measure overflows the viewport", not "the cursor itself crosses an edge" — mirrors
    /// `ScorePiPFrameRenderer.measureDocRect`. Scans every system so honored layout breaks (multi-row layouts) resolve.
    private func measureRect(for cursor: ScoreCursor, in doc: LayoutDocument) -> CGRect? {
        for system in doc.systems {
            if let measure = system.measures.first(where: { $0.measureIndex == cursor.measureIndex }) {
                return CGRect(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                    width: measure.width,
                    height: system.size.height,
                )
            }
        }
        return nil
    }

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside the viewport with `pad` margin. Same shape as
    /// `VerticalScoreContainer.adjustedScrollOffset`.
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
        let showInvisibleElements: Bool
        let transposeSemitones: Int

        init(
            score: Score,
            size: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            showInvisibleElements: Bool,
            transposeSemitones: Int,
        ) {
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
                ^ (transposeSemitones << 24)
            self.size = size
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
            self.showInvisibleElements = showInvisibleElements
            self.transposeSemitones = transposeSemitones
        }
    }
}

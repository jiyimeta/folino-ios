import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a `ScoreScrollHost` (UIKit-backed) and recomputes the `LayoutDocument`
/// whenever the score, staff size, or container width changes.
///
/// Drives playback auto-scroll: when `playbackCursor` moves outside the viewport, an animated scroll command brings
/// the cursor's frame back inside with a small padding inset. Horizontal follow only kicks in once `viewportZoom`
/// makes the content wider than the viewport.
///
/// Owns pinch zoom. The score content is `scaleEffect`-ed *inside* the scroll host (with an explicit scaled `.frame`)
/// so the underlying `UIScrollView` is never zoomed — `maximumZoomScale` is pinned at 1 and it scrolls the zoomed
/// extent natively. That keeps the SwiftUI `Canvas` re-rasterising under `scaleEffect` (sharp throughout) instead of
/// falling back to a `CALayer` bitmap upscale.
///
/// During a live pinch, two `scaleEffect`s compose: inner `pinch.magnification` with `anchor: pinch.anchor` pivots the
/// visual around the user's fingers; outer committed `viewportZoom` with `anchor: .topLeading` drives the `.frame`
/// size and scrollable extent. On gesture end the live factor is folded into `viewportZoom` and a scroll command is
/// queued so the pinch's content point stays under the same viewport coord.
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var contentInsetTop: CGFloat = 0
    /// System top safe-area inset only — parent's overlay augmentation is subtracted back out below.
    @State private var safeAreaTop: CGFloat = 0
    /// Live pinch state held as `@Observable` so mutations propagate into the hosted score subtree via observation —
    /// not through `rootView` reassignment, which drops the `withAnimation { … }` transaction. See `PinchState`.
    @State private var pinch = PinchState()
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE `withAnimation` so the `expectedContentSize` closure reads the
    /// final committed value instead of SwiftUI's interpolated values during a commit transition.
    @State private var committedZoom: CGFloat = 1.0

    /// Vertical padding inside the scaled content. Top is larger so the first system clears the nav chrome / safe
    /// area when `ignoresSafeArea()` lets the score slide underneath.
    private let scoreTopPadding: CGFloat = 44
    private let scoreBottomPadding: CGFloat = 16

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            // Any horizontal overflow in `doc.size.width` (engine right margin, spanners, ties) is absorbed by
            // `effectiveZoom`'s fit-to-width factor so the user always sees the entire system at user-zoom 1.0.
            let layoutWidth = max(proxy.size.width, staffSize * 4)
            scrollContent(viewport: proxy.size)
                .task(id: TaskKey(
                    score: score, size: staffSize, width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    showInvisibleElements: showInvisibleElements,
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
        }
        .background {
            // Sibling reader extending beyond safe area (the main GR sits inside it and reports zero). Subtracts the
            // parent overlay augmentation to leave just the system inset.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    max(0, proxy.safeAreaInsets.top - ReaderTopOverlay.height)
                } action: { newValue in
                    safeAreaTop = newValue
                }
        }
    }

    private func scrollContent(viewport: CGSize) -> some View {
        ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: true,
            alwaysBounceHorizontal: false,
            centerVertically: false,
            centerHorizontally: false,
            expectedContentSize: {
                guard let doc = document else { return .zero }
                let fit = doc.size.width > 0
                    ? min(1.0, viewport.width / doc.size.width)
                    : 1.0
                let zoom = committedZoom * fit
                let topPad = scoreTopPadding + safeAreaTop
                return CGSize(
                    width: doc.size.width * zoom,
                    height: (doc.size.height + topPad + scoreBottomPadding) * zoom,
                )
            },
            onPinchBegan: { anchor, _ in
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
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
                commitPinch(
                    magnification: magnification,
                    startLocation: startLocation,
                    currentOffset: currentOffset,
                    viewport: viewport,
                )
            },
        ) {
            VerticalZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                score: score,
                viewport: viewport,
                scoreTopPadding: scoreTopPadding,
                scoreBottomPadding: scoreBottomPadding,
                safeAreaTop: safeAreaTop,
                scoreOptions: scoreOptions,
                playbackCursor: playbackCursor,
                lastManualCursor: $lastManualCursor,
            )
        }
        // `UIViewRepresentable` resolves safe area by shrinking its UIView frame — can't surface it as
        // `contentInsets` the way SwiftUI's own `ScrollView` does. Overlays sit on top in a ZStack, so the score
        // sliding under them is intentional.
        .ignoresSafeArea()
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
    }

    /// User zoom scaled by a fit-to-width factor so rendered content never exceeds the viewport horizontally at
    /// user-zoom 1.0 — "zoom 1.0 = fit width", regardless of engine margins / spanners / ties / playback chrome
    /// contributing to `doc.size.width`.
    private func effectiveZoom(
        for doc: LayoutDocument, viewport: CGSize,
    ) -> CGFloat {
        let fit = doc.size.width > 0
            ? min(1.0, viewport.width / doc.size.width)
            : 1.0
        return viewModel.viewportZoom * fit
    }

    /// Folds a finished pinch into `viewportZoom` and queues a scroll so the content under the user's fingers at
    /// release lands on the same screen position post-commit. Vertical pan-during-pinch rides on `currentOffset`
    /// (UIScrollView native); horizontal rides on `pinch.offsetX`.
    ///
    /// `newOffset = startLocation * (ratio - 1) + currentOffset − (pinch.offsetX, 0)`
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
            x: max(0, currentOffset.x + startLocation.x * (ratio - 1) - pinch.offsetX),
            y: max(0, currentOffset.y + startLocation.y * (ratio - 1)),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        if isBounceBack {
            // Rubber-band release from baseline 1.0. `pinch.anchor` is intentionally left at the gesture's start
            // anchor — animating it toward `.center` would interpolate the scale pivot and read as judder.
            withAnimation(.smooth(duration: 0.18)) {
                pinch.magnification = 1.0
                pinch.offsetX = 0
            }
        } else {
            committedZoom = targetZoom
            pendingScroll = .immediate(scrollToTarget)
            let snapToUnit = targetZoom <= 1.0
            if snapToUnit {
                // Snap-to-unit from a non-unit base. Naïvely animating both `viewportZoom` (`base → target`) and
                // `pinch.magnification` (`gr.scale → 1`) together makes their product bulge mid-animation — for a
                // 3× → 1× zoom-out the combined visible scale overshoots 1.0 by ~30% at the midpoint. Decompose
                // into two phases: (1) synchronous snap — set post-commit `viewportZoom` and compensate
                // magnification to `combined / targetZoom`, so visible scale (`viewportZoom × magnification`) is
                // invariant; (2) animated decay — in the next runloop tick animate magnification → 1.0, so visible
                // scale moves monotonically `combined → 1.0`. The async hop makes SwiftUI treat the compensated
                // value as the animation's starting point.
                let compensatedMag = combined / targetZoom
                viewModel.resetZoom()
                pinch.magnification = compensatedMag
                DispatchQueue.main.async {
                    withAnimation(.smooth(duration: 0.18)) {
                        pinch.magnification = 1.0
                        pinch.offsetX = 0
                    }
                }
            } else {
                // Real zoom-in / zoom-out. Combined visible scale is invariant across the commit
                // (`baseZoom × gr.scale = targetZoom × 1.0`); interpolating each factor separately would bulge along
                // the easing curve and read as an unwanted scale animation. Snap the scale state, animate only the
                // live offset reset, and only when the scroll view can't absorb it.
                viewModel.viewportZoom = targetZoom
                pinch.magnification = 1.0
                pinch.anchor = .center

                let docWidth = document?.size.width ?? 0
                let postFramedWidth = min(docWidth, viewport.width) * targetZoom
                let scrollAbsorbsOffset = postFramedWidth > viewport.width
                if pinch.offsetX != 0, !scrollAbsorbsOffset {
                    withAnimation(.smooth(duration: 0.18)) {
                        pinch.offsetX = 0
                    }
                } else {
                    pinch.offsetX = 0
                }
            }
        }
    }

    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: true, includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
            showsInvisibleElements: showInvisibleElements,
        )
    }

    private func rebuildLayout(width: CGFloat) async {
        let score = score
        let options = scoreOptions
        let newDoc = await Task.detached(priority: .userInitiated) {
            LayoutEngine.layout(
                score: score, options: options, availableWidth: width,
            )
        }.value
        guard !Task.isCancelled else { return }
        document = newDoc
        lastWidth = width
    }

    private func autoScroll(
        cursor: ScoreCursor?,
        viewport: CGSize,
    ) {
        guard let cursor, let doc = document,
              let rect = doc.cursorFrame(for: cursor, in: score)
        else { return }

        let zoom = effectiveZoom(for: doc, viewport: viewport)
        let pad = 8 * doc.metrics.sp * zoom

        // Cursor frame in scroll-content coords: vertical padding only, then scaled from top-leading. Mirrors
        // `zoomedSurface`'s composition (no horizontal padding).
        let topPad = scoreTopPadding + safeAreaTop
        let minX = rect.minX * zoom
        let maxX = rect.maxX * zoom
        let minY = (rect.minY + topPad) * zoom
        let maxY = (rect.maxY + topPad) * zoom

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

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside the viewport with `pad` margin. Returns
    /// `currentOffset` unchanged when the target is already fully visible — preserves manual horizontal panning while
    /// playback advances within the visible row.
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
        let width: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool
        let showInvisibleElements: Bool

        init(
            score: Score,
            size: CGFloat,
            width: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            showInvisibleElements: Bool,
        ) {
            // `Score` is Equatable but not Hashable. Use a cheap identity proxy: structural shape + opening clefs.
            // The opening-clef hash is what makes a clef override (a field-level edit that leaves parts.count / staff
            // count unchanged) re-trigger this `.task(id:)`.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
            self.showInvisibleElements = showInvisibleElements
        }
    }
}

// swiftlint:disable file_length
// VerticalScoreContainer hosts the UIKit-backed scroll / pinch / zoom pipeline plus the layout, fit-to-width, and
// auto-scroll plumbing for the vertical Reader; its breadth keeps it just over the file_length budget.

import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a `ScoreScrollHost` (UIKit-backed) and recomputes the `LayoutDocument`
/// whenever the score, staff size, or container width changes.
///
/// Drives playback auto-scroll: during playback it pins the playing cursor's system to the top of the viewport,
/// re-scrolling only when that system or the lookahead cursor (`scrollAnchorCursor`, a couple beats ahead) leaves
/// the viewport — so the cursor drifts down between scrolls. When paused / scrubbing it falls back to a gentle
/// keep-in-view. Horizontal follow only kicks in once `viewportZoom` makes the content wider than the viewport.
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
    /// Lookahead anchor used for auto-scroll ONLY — a cursor a couple of beats ahead of `playbackCursor` during
    /// playback, so the viewport scrolls before the playing cursor reaches the edge. `nil` when not playing /
    /// scrubbing, in which case auto-scroll falls back to `playbackCursor`. Never passed to the highlight.
    let scrollAnchorCursor: ScoreCursor?
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `TaskKey` — the score passed in is
    /// already transposed. Without this the `TaskKey.scoreSignature` hash doesn't change on transpose and the layout
    /// task never re-runs.
    let transposeSemitones: Int
    /// Content height the bottom transport control reserves above the bottom safe area (collapsed pill or expanded seek
    /// card). The scroll content pads its bottom by this plus the bottom safe-area inset — i.e. the full distance from
    /// the control's top edge to the screen's bottom edge — so the last system clears the control when scrolled fully
    /// down. The control floats over this padding in a sibling overlay; vertical mode reserves no `safeAreaPadding`.
    let bottomControlClearance: CGFloat
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
    /// System bottom safe-area inset (home-indicator region). Added to `bottomControlClearance` so the scroll content's
    /// bottom padding spans from the transport control's top edge all the way to the physical screen bottom.
    @State private var safeAreaBottom: CGFloat = 0
    /// Live pinch state held as `@Observable` so mutations propagate into the hosted score subtree via observation —
    /// not through `rootView` reassignment, which drops the `withAnimation { … }` transaction. See `PinchState`.
    @State private var pinch = PinchState()
    /// Mirror of `viewModel.viewportZoom` set OUTSIDE `withAnimation` so the `expectedContentSize` closure reads the
    /// final committed value instead of SwiftUI's interpolated values during a commit transition.
    @State private var committedZoom: CGFloat = 1.0

    /// Vertical padding inside the scaled content. Top is larger so the first system clears the nav chrome / safe
    /// area when `ignoresSafeArea()` lets the score slide underneath.
    private let scoreTopPadding: CGFloat = 44
    /// Bottom padding inside the scaled content: the full clearance from the transport control's top edge to the
    /// physical screen bottom (control content height + bottom safe area). Lets the last system scroll out from under
    /// the floating control so the whole score is visible at the bottom of the scroll.
    private var scoreBottomPadding: CGFloat {
        bottomControlClearance + safeAreaBottom
    }

    /// Horizontal inset applied to the score on iPad (0 on iPhone) so Vertical mode matches Page mode's score width
    /// and keeps comfortable margins off the bezel. See `ReaderScoreLayout`.
    private func scoreInset(viewportWidth: CGFloat) -> CGFloat {
        ReaderScoreLayout.scoreHorizontalInset(viewportWidth: viewportWidth, phoneDefault: 0)
    }

    private struct PinchSession {
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            // Any horizontal overflow in `doc.size.width` (engine right margin, spanners, ties) is absorbed by
            // `effectiveZoom`'s fit-to-width factor so the user always sees the entire system at user-zoom 1.0.
            // iPad insets the score by a horizontal margin (matching Page mode); the score lays out at the inset width
            // and the surface re-applies the same margin so it sits centered with bezel clearance.
            let layoutWidth = max(
                proxy.size.width - scoreInset(viewportWidth: proxy.size.width) * 2,
                staffSize * 4,
            )
            scrollContent(viewport: proxy.size)
                .onAppear { eagerLayoutIfNeeded(width: layoutWidth) }
                .onChange(of: layoutWidth) { _, newWidth in eagerLayoutIfNeeded(width: newWidth) }
                .task(id: TaskKey(
                    score: score, size: staffSize, width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    showInvisibleElements: showInvisibleElements,
                    transposeSemitones: transposeSemitones,
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
                .onGeometryChange(for: CGFloat.self) { proxy in
                    max(0, proxy.safeAreaInsets.bottom)
                } action: { newValue in
                    safeAreaBottom = newValue
                }
        }
    }

    // swiftlint:disable:next function_body_length
    private func scrollContent(viewport: CGSize) -> some View {
        // Observe the live pinch magnification here so the container re-renders each frame of a commit reset animation;
        // that re-runs the host's annotation-canvas sync, so the ink eases in lockstep with the score.
        _ = pinch.magnification
        return ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            alwaysBounceVertical: true,
            alwaysBounceHorizontal: false,
            centerVertically: false,
            centerHorizontally: false,
            expectedContentSize: {
                guard let doc = document else { return .zero }
                // Fit the *padded* content (score + horizontal inset) into the viewport so the inset score lands
                // centered with bezel margins, mirroring `VerticalZoomedSurface`'s framed width.
                let framedContentWidth = doc.size.width + scoreInset(viewportWidth: viewport.width) * 2
                let fit = framedContentWidth > 0
                    ? min(1.0, viewport.width / framedContentWidth)
                    : 1.0
                let zoom = committedZoom * fit
                let topPad = scoreTopPadding + safeAreaTop
                return CGSize(
                    width: framedContentWidth * zoom,
                    height: (doc.size.height + topPad + scoreBottomPadding) * zoom,
                )
            },
            onPinchBegan: { anchor, _ in
                pinch.cancelResetAnimation() // don't let a trailing commit ease fight the new gesture
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
            annotationOverlay: annotationSpec(viewport: viewport),
        ) {
            VerticalZoomedSurface(
                viewModel: viewModel,
                pinch: pinch,
                document: document,
                score: score,
                viewport: viewport,
                horizontalPadding: scoreInset(viewportWidth: viewport.width),
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
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { _, _ in
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
    }

    /// Geometry the annotation canvas mirrors onto PencilKit's own scroll machinery (read at call time by the host's
    /// sync, so the ink tracks the score during scroll/pinch). The canvas view is viewport-sized; PencilKit holds the
    /// tall document in its own contentSize/zoomScale/contentOffset — which keeps the live-stroke render surface under
    /// the Metal texture limit (the fix for the draw-time enlarge).
    /// Opt-in annotation overlay config for the host. The `state` closure recomputes the canvas mirror geometry at
    /// call time (read by the host's scroll/pinch sync), so it tracks without a SwiftUI render round-trip.
    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            drawingData: viewModel.annotationDrawingData,
            onChange: { data, isEmpty in viewModel.annotationDrawingDidChange(data, isEmpty: isEmpty) },
            state: { annotationCanvasState(viewport: viewport) },
        )
    }

    private func annotationCanvasState(viewport: CGSize) -> AnnotationCanvasState {
        guard let doc = document else {
            return AnnotationCanvasState(
                documentSize: .zero, zoomScale: 1, contentOffsetBias: .zero, contentInset: .zero,
            )
        }
        let zoomC = effectiveZoom(for: doc, viewport: viewport) // committed zoom (no live magnification)
        let m = pinch.magnification
        let z = zoomC * m
        let topPad = scoreTopPadding + safeAreaTop
        let hPad = scoreInset(viewportWidth: viewport.width)
        let paddedW = doc.size.width + hPad * 2
        let paddedH = doc.size.height + topPad + scoreBottomPadding
        // The score applies the live pinch as `.scaleEffect(magnification, anchor: pinch.anchor)` BEFORE the committed
        // zoom, pivoting around the finger centroid. The canvas mirrors that pivot via contentOffset: a doc point p
        // lands at the same screen point as the score, which expands to
        //   screen(p) = (p + pad) * m * zoomC + anchor * (1 - m) * zoomC - scrollOffset [+ pinch.offsetX]
        // so canvas.contentOffset = scrollOffset - pad*z - anchor*(1-m)*zoomC - offsetX. The host adds the scroll
        // view's REAL contentOffset to the bias below. At rest (m == 1) the anchor term vanishes.
        let anchorTermX = pinch.anchor.x * paddedW * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * paddedH * (1 - m) * zoomC
        // A large symmetric inset keeps the (anchor-shifted) contentOffset inside PencilKit's valid range so it is
        // never clamped during a pinch. The canvas's own pan is disabled, so the extra scroll range is unreachable.
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: doc.size,
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -hPad * z - anchorTermX - pinch.offsetX,
                y: -topPad * z - anchorTermY,
            ),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    /// User zoom scaled by a fit-to-width factor so rendered content never exceeds the viewport horizontally at
    /// user-zoom 1.0 — "zoom 1.0 = fit width", regardless of engine margins / spanners / ties / playback chrome
    /// contributing to `doc.size.width`.
    private func effectiveZoom(
        for doc: LayoutDocument, viewport: CGSize,
    ) -> CGFloat {
        // Fit the padded content (score + horizontal inset) so the inset never pushes the score past the viewport.
        let framedContentWidth = doc.size.width + scoreInset(viewportWidth: viewport.width) * 2
        let fit = framedContentWidth > 0
            ? min(1.0, viewport.width / framedContentWidth)
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
            // anchor — animating it toward `.center` would interpolate the scale pivot and read as judder. The reset
            // eases frame-by-frame (PinchState.animateReset) so the annotation ink overlay follows it in lockstep.
            pinch.animateReset(toMagnification: 1.0, offsetX: 0)
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
                // Snap-to-unit from a non-unit base. Set the post-commit zoom and compensate magnification so the
                // visible scale (viewportZoom × magnification) is invariant at the commit instant, then ease
                // magnification → 1.0 frame-by-frame so visible scale moves monotonically `combined → 1.0`.
                let compensatedMag = combined / targetZoom
                viewModel.resetZoom()
                pinch.magnification = compensatedMag
                pinch.animateReset(toMagnification: 1.0, offsetX: 0)
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
                    pinch.animateReset(toMagnification: pinch.magnification, offsetX: 0)
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

    /// SwiftUI `#Preview` snapshots the view tree before the async `.task` (which hops to a detached background
    /// `LayoutEngine.layout`) completes, so `document` is still nil and the score area renders blank. When running
    /// under Xcode Previews, lay the score out synchronously on first appearance so the snapshot has a populated
    /// `document`. No-op in the real app / live capture (those let the async path run and never enter this branch).
    private func eagerLayoutIfNeeded(width: CGFloat) {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" else { return }
        // Re-lay out whenever the width changes (not only when nil): `onAppear` can fire before the GeometryReader
        // settles to its final width, so the first synchronous layout may be narrower than the viewport (leaving a
        // right-side gap). Re-running on width change ensures the snapshot uses the settled width and fills the view.
        guard document == nil || width != lastWidth else { return }
        document = LayoutEngine.layout(score: score, options: scoreOptions, availableWidth: width)
        lastWidth = width
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
        realCursor: ScoreCursor?,
        lookaheadCursor: ScoreCursor?,
        viewport: CGSize,
    ) {
        guard let realCursor, let doc = document,
              let realRect = doc.cursorFrame(for: realCursor, in: score)
        else { return }

        let zoom = effectiveZoom(for: doc, viewport: viewport)
        let pad = 8 * doc.metrics.sp * zoom

        // Frames in scroll-content coords: scaled from top-leading. Mirrors `VerticalZoomedSurface`'s composition —
        // vertical padding on top/bottom, and (on iPad) a horizontal inset that shifts the score's content-space x
        // rightward before scaling. `cursorFrame` spans every staff in the system, so its Y range is the system span.
        let topPad = scoreTopPadding + safeAreaTop
        let hPad = scoreInset(viewportWidth: viewport.width)
        let realMinX = (realRect.minX + hPad) * zoom
        let realMaxX = (realRect.maxX + hPad) * zoom
        let realMinY = (realRect.minY + topPad) * zoom
        let realMaxY = (realRect.maxY + topPad) * zoom

        let curX = liveScrollOffset.x
        let curY = liveScrollOffset.y

        // Horizontal follow is unchanged — keep the playing cursor's column in view (only relevant when zoomed).
        let newX = adjustedScrollOffset(
            currentOffset: curX,
            targetMin: realMinX, targetMax: realMaxX,
            viewportSize: viewport.width, pad: pad,
        )

        let newY: CGFloat
        if let lookaheadCursor, let lookRect = doc.cursorFrame(for: lookaheadCursor, in: score) {
            // Playback: pin the playing cursor's system to the top, re-scrolling only when that system or the
            // lookahead (a couple beats ahead) leaves the viewport — so the cursor drifts down between scrolls.
            // The pinned system top lands `overlayClearance` points below the screen top — clear of the floating
            // top overlay (Back / inspector buttons), which occupies `safeAreaTop + ReaderTopOverlay.height`. This is
            // a SCREEN-space distance (not zoom-scaled): `contentOffset` shares the scaled-content point space, so
            // the system top appears at screen-y == `overlayClearance` regardless of zoom. The 8 pt gap keeps the
            // staff off the overlay's glass + shadow.
            let lookMaxY = (lookRect.maxY + topPad) * zoom
            let overlayClearance = safeAreaTop + ReaderTopOverlay.height + 8
            newY = CGFloat(scrollOffsetPinningSystemTop(
                current: Double(curY),
                systemMin: Double(realMinY),
                systemMax: Double(realMaxY),
                lookaheadMax: Double(lookMaxY),
                viewport: Double(viewport.height),
                topInset: Double(overlayClearance),
            ))
        } else {
            // Paused / scrubbing / manual seek: gentle keep-in-view so a tap-to-seek doesn't jump the system to top.
            newY = adjustedScrollOffset(
                currentOffset: curY,
                targetMin: realMinY, targetMax: realMaxY,
                viewportSize: viewport.height, pad: pad,
            )
        }

        if abs(newX - curX) < 0.5, abs(newY - curY) < 0.5 { return }

        pendingScroll = .animated(CGPoint(x: newX, y: newY))
    }

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside the viewport with `pad` margin. Returns
    /// `currentOffset` unchanged when the target is already fully visible — preserves manual horizontal panning while
    /// playback advances within the visible row. Delegates to the shared `Domain.scrollOffsetKeepingInView` so iOS
    /// and Android follow the cursor identically (parity: one implementation, no divergent Kotlin port).
    private func adjustedScrollOffset(
        currentOffset cur: CGFloat,
        targetMin: CGFloat,
        targetMax: CGFloat,
        viewportSize: CGFloat,
        pad: CGFloat,
    ) -> CGFloat {
        CGFloat(scrollOffsetKeepingInView(
            current: Double(cur),
            targetMin: Double(targetMin),
            targetMax: Double(targetMax),
            viewport: Double(viewportSize),
            pad: Double(pad),
        ))
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool
        let showInvisibleElements: Bool
        let transposeSemitones: Int

        init(
            score: Score,
            size: CGFloat,
            width: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
            showInvisibleElements: Bool,
            transposeSemitones: Int,
        ) {
            // `Score` is Equatable but not Hashable. Use a cheap identity proxy: structural shape + opening clefs.
            // The opening-clef hash is what makes a clef override (a field-level edit that leaves parts.count / staff
            // count unchanged) re-trigger this `.task(id:)`.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
                ^ (transposeSemitones << 24)
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
            self.showInvisibleElements = showInvisibleElements
            self.transposeSemitones = transposeSemitones
        }
    }
}

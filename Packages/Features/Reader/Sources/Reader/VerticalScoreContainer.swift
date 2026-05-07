import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a vertical `ScrollView` and
/// recomputes the `LayoutDocument` whenever the score, staff size, or
/// container width changes. Holding the document on this view (instead
/// of letting `ScoreView`'s convenience init re-run layout each pass)
/// keeps re-layout cost confined to real input changes — and makes the
/// document available to a future `ScoreHitTester` without rebuilding.
///
/// Drives playback auto-scroll: when `playbackCursor` moves outside the
/// viewport in either axis, `ScrollPosition.scrollTo(point:)` brings the
/// cursor's frame back inside with a small padding inset. Horizontal
/// follow only kicks in once `viewportZoom` makes the content wider than
/// the viewport — at zoom 1.0 the score wraps to fit and X never moves.
///
/// Owns the pinch / double-tap zoom gestures. The score content is
/// `scaleEffect`-ed *inside* the `ScrollView` (with an explicit scaled
/// `.frame`) so the `ScrollView` itself is never zoomed — its viewport
/// stays fixed and it scrolls the zoomed extent natively.
///
/// During a live pinch, two `scaleEffect`s compose:
///   * inner `liveMagnification` with `anchor: liveMagAnchor` (the gesture
///     start anchor reported by `MagnifyGesture`) — pivots the visual
///     around the user's fingers without changing layout;
///   * outer committed `viewportZoom` with `anchor: .topLeading` — the
///     persistent scale that drives the `.frame` size and `ScrollView`
///     scrollable extent.
/// On gesture end the live factor is folded into `viewportZoom` and
/// `ScrollPosition` is shifted so the pinch's content point stays under
/// the same viewport coord — equivalent to UIScrollView's
/// `viewForZooming` behaviour, just expressed in SwiftUI.
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var scrollPosition = ScrollPosition()
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    /// Scroll target queued in `onEnded` to be applied once
    /// `viewportZoom`'s state change has propagated to a new
    /// `ScrollView` `contentSize`. Applying `scrollTo` in the same
    /// transaction as a `viewportZoom` change clamps the offset to the
    /// *old* `maxScroll`, so for zoom-in the anchor lands ~`(framedHeight_pre - framedHeight_post)/2`
    /// below the user's pinch — visible as a "1-staff drift down."
    @State private var pendingPinchScroll: CGPoint?
    /// `ScrollView` top inset (safe area + nav chrome). Needed because
    /// `scrollPosition.scrollTo(point: P)` with `anchor: .topLeading`
    /// places content y = P at the *visible* (inset-adjusted) top —
    /// i.e. the resulting `contentOffset = P − topInset`. Our pinch
    /// formula computes the target in `contentOffset` units, so we
    /// add `topInset` back when we hand the value to `scrollTo`.
    @State private var contentInsetTop: CGFloat = 0

    // Tracked as `@State` (not `@GestureState`) so they don't auto-reset
    // before `onEnded` runs — that auto-reset would visibly snap the
    // inner `scaleEffect` back to identity at the moment of release,
    // expanding content away from the pinch anchor by `1 - mag`.
    // Manually resetting in `onEnded` (alongside the `viewportZoom`
    // commit and the scroll shift) lets the visual transition happen
    // atomically in a single render pass.
    @State private var liveMagnification: CGFloat = 1.0
    @State private var liveMagAnchor: UnitPoint = .center

    /// Vertical padding that lives inside the scaled content so the
    /// first / last system don't butt up against the viewport edges.
    /// Scales with the score because it's applied inside the
    /// `scaleEffect`. No horizontal counterpart: at zoom 1.0 we want the
    /// score to span the full viewport width edge-to-edge.
    private let scoreVerticalPadding: CGFloat = 16

    /// Captured at the first `onChanged` of a pinch so the gesture-end
    /// commit can shift `ScrollPosition` by `start * (mag - 1)` without
    /// fighting any user scrolling that happens during the gesture.
    private struct PinchSession {
        var initialScrollOffset: CGPoint
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            // Hand the full viewport width to layout. Any horizontal
            // overflow in the resulting `doc.size.width` (engine right
            // margin, spanners, ties) is absorbed by `effectiveZoom`'s
            // fit-to-width factor below — so the user always sees the
            // entire system at user-zoom 1.0 with no side margin.
            let layoutWidth = max(proxy.size.width, staffSize * 4)
            scrollContent(viewport: proxy.size)
                .task(id: TaskKey(
                    score: score, size: staffSize, width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
        }
    }

    @ViewBuilder
    private func scrollContent(viewport: CGSize) -> some View {
        ScrollView([.vertical, .horizontal]) {
            zoomedSurface(viewport: viewport)
        }
        // Pin the score's top-leading to the viewport's top-leading. Without
        // this, the ScrollView's default anchor preserves the content's
        // *centre* across size changes — and our content goes from 0×0
        // (`Color.clear` while `document == nil`) to the full layout size
        // once `rebuildLayout` finishes. Center-anchoring that growth
        // visibly opens the score around the middle of the page on first
        // paint. iPad makes it more obvious because `NavigationSplitView`
        // re-runs the geometry pass as the detail column negotiates width,
        // re-firing layout and growing the content size each time.
        .defaultScrollAnchor(.topLeading)
        .scrollPosition($scrollPosition, anchor: .topLeading)
        .simultaneousGesture(doubleTapGesture)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            geometry.contentOffset
        } action: { _, newOffset in
            liveScrollOffset = newOffset
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentInsets.top
        } action: { _, newTop in
            contentInsetTop = newTop
        }
        .onChange(of: viewModel.viewportZoom) { _, _ in
            // After a pinch zoom commit, apply the queued scroll once
            // the new `viewportZoom` has produced a new `contentSize`
            // — calling `scrollTo` in the same transaction as the
            // `viewportZoom` change clamps the offset to the old
            // `maxScroll`.
            if let target = pendingPinchScroll {
                pendingPinchScroll = nil
                scrollPosition.scrollTo(point: target)
            }
        }
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
    }

    @ViewBuilder
    private func zoomedSurface(viewport: CGSize) -> some View {
        if let doc = document {
            let zoom = effectiveZoom(for: doc, viewport: viewport)
            let framedWidth = doc.size.width * zoom
            let framedHeight = (doc.size.height + 2 * scoreVerticalPadding) * zoom
            scoreSurface(document: doc)
                .padding(.vertical, scoreVerticalPadding)
                .scaleEffect(liveMagnification, anchor: liveMagAnchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: framedWidth,
                    height: framedHeight,
                    alignment: .topLeading
                )
                .simultaneousGesture(magnifyGesture)
        } else {
            Color.clear
        }
    }

    /// User zoom scaled by a fit-to-width factor so the rendered content
    /// never exceeds the viewport horizontally at user-zoom 1.0.
    /// `LayoutEngine.layout` reports `doc.size.width = totalSystemExtent
    /// + 2*sp`; spanners / ties / playback chrome can also extend slightly
    /// past that. Rather than chase every contribution, we measure the
    /// actual `doc.size.width` and shrink to fit when it exceeds the
    /// viewport — the user-visible behaviour is "zoom 1.0 = fit width".
    private func effectiveZoom(
        for doc: LayoutDocument, viewport: CGSize
    ) -> CGFloat {
        let fit = doc.size.width > 0
            ? min(1.0, viewport.width / doc.size.width)
            : 1.0
        return viewModel.viewportZoom * fit
    }

    @ViewBuilder
    private func scoreSurface(document doc: LayoutDocument) -> some View {
        ScoreView(
            document: doc, score: score,
            playbackCursor: playbackCursor,
            playbackCursorColor: .accentColor
        )
        .coordinateSpace(name: "scoreSurface")
        .gesture(tapSeekGesture(document: doc))
        .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)
    }

    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named("scoreSurface"))
            .onEnded { value in
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchSession == nil {
                    pinchSession = PinchSession(
                        initialScrollOffset: liveScrollOffset,
                        baseZoom: viewModel.viewportZoom
                    )
                }
                liveMagnification = value.magnification
                liveMagAnchor = value.startAnchor
            }
            .onEnded { value in
                let session = pinchSession ?? PinchSession(
                    initialScrollOffset: liveScrollOffset,
                    baseZoom: viewModel.viewportZoom
                )
                pinchSession = nil

                let combined = session.baseZoom * value.magnification
                let targetZoom: CGFloat = combined < 1.05 ? 1.0 : combined
                let ratio = targetZoom / session.baseZoom

                // Shift scroll so the framed pinch point at
                // `startLocation` (in the gesture view's local coords,
                // i.e. pre-commit framed coords) stays at the same
                // viewport coord. Frame scales from top-leading by
                // `ratio`, so the offset shift is `startLocation *
                // (ratio - 1)`.
                // `scrollTo` with `anchor: .topLeading` aligns content
                // y = target to the *visible* (inset-adjusted) top, so
                // the resulting `contentOffset.y = target − topInset`.
                // Compute the desired `contentOffset` for visual
                // continuity, then add `contentInsetTop` for the call.
                let p = value.startLocation
                let scrollToTarget = CGPoint(
                    x: max(0, session.initialScrollOffset.x + p.x * (ratio - 1)),
                    y: max(0, session.initialScrollOffset.y + p.y * (ratio - 1)) + contentInsetTop
                )

                let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
                if isBounceBack {
                    // Rubber-band release: user pinched below 1.0 from
                    // a baseline of 1.0. No actual zoom or scroll
                    // commit — just animate the inner `liveMagnification`
                    // back to identity so the visual snap from compressed
                    // back to layout is a smooth motion (matches
                    // `UIScrollView`'s bounce feel) instead of an abrupt
                    // jump that pulls content away from the anchor.
                    //
                    // Important: keep `liveMagAnchor` at the gesture's
                    // start anchor for the duration of the animation.
                    // Animating it toward `.center` would interpolate
                    // the scale pivot mid-bounce, sliding the content
                    // visibly toward the frame center — visible as
                    // "judder". At `mag = 1.0` the anchor is irrelevant
                    // so we just leave the stale value behind; the next
                    // pinch's `onChanged` overwrites it.
                    withAnimation(.smooth(duration: 0.15)) {
                        liveMagnification = 1.0
                    }
                } else {
                    // Real zoom commit (in or out from a non-unit base).
                    // Queue the scroll target — the `onChange(of:
                    // viewportZoom)` handler applies it once
                    // `ScrollView`'s `contentSize` is updated, so the
                    // offset isn't clamped to the pre-zoom `maxScroll`.
                    // `viewportZoom`, `liveMagnification`, and
                    // `liveMagAnchor` still commit atomically here so
                    // outer-scale grows by `ratio` while inner-scale
                    // drops to identity in the same render — no
                    // visible flicker around the pinch anchor.
                    pendingPinchScroll = scrollToTarget
                    if targetZoom <= 1.0 {
                        viewModel.resetZoom()
                    } else {
                        viewModel.viewportZoom = targetZoom
                        viewModel.captureCurrentZoomAsLast()
                    }
                    liveMagnification = 1.0
                    liveMagAnchor = .center
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                viewModel.toggleZoom(targetIfZoomedOut: 2.0)
            }
    }

    private func rebuildLayout(width: CGFloat) {
        let opts = ScoreViewOptions(
            staffSize: staffSize,
            systemGap: staffSize * 1.25,
            wrapToViewWidth: true,
            includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false
        )
        document = LayoutEngine.layout(
            score: score, options: opts, availableWidth: width
        )
        lastWidth = width
    }

    private func autoScroll(
        cursor: ScoreCursor?,
        viewport: CGSize
    ) {
        guard let cursor, let doc = document,
              let rect = doc.cursorFrame(for: cursor, in: score)
        else { return }

        // Mirror `zoomedSurface`'s effective scale (user zoom × fit-to-width)
        // so cursor-frame coordinates match the rendered scroll-content size.
        let zoom = effectiveZoom(for: doc, viewport: viewport)
        let pad = 8 * doc.metrics.sp * zoom

        // Cursor frame in scroll-content coords: vertical padding only,
        // then scaled from top-leading. Mirrors `zoomedSurface`'s
        // composition (no horizontal padding).
        let minX = rect.minX * zoom
        let maxX = rect.maxX * zoom
        let minY = (rect.minY + scoreVerticalPadding) * zoom
        let maxY = (rect.maxY + scoreVerticalPadding) * zoom

        let curX = liveScrollOffset.x
        let curY = liveScrollOffset.y

        let newX = adjustedScrollOffset(
            currentOffset: curX,
            targetMin: minX, targetMax: maxX,
            viewportSize: viewport.width, pad: pad
        )
        let newY = adjustedScrollOffset(
            currentOffset: curY,
            targetMin: minY, targetMax: maxY,
            viewportSize: viewport.height, pad: pad
        )

        if abs(newX - curX) < 0.5, abs(newY - curY) < 0.5 { return }

        withAnimation(.easeInOut(duration: 0.25)) {
            scrollPosition.scrollTo(point: CGPoint(x: newX, y: newY))
        }
    }

    /// Smallest scroll offset that keeps `[targetMin, targetMax]` inside
    /// the viewport with `pad` margin. Returns `currentOffset` unchanged
    /// when the target is already fully visible — preserves manual
    /// horizontal panning while playback advances within the visible row.
    private func adjustedScrollOffset(
        currentOffset cur: CGFloat,
        targetMin: CGFloat,
        targetMax: CGFloat,
        viewportSize: CGFloat,
        pad: CGFloat
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

    /// Hashable composite key so `.task(id:)` re-runs only when one of
    /// the inputs to layout actually changes.
    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool

        init(score: Score, size: CGFloat, width: CGFloat, honorLayoutBreaks: Bool) {
            // `Score` is Equatable but not Hashable. Use a cheap
            // identity proxy: parts.count + total staves + division.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
        }
    }
}

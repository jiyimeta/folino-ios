// swiftlint:disable file_length
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a `ScoreScrollHost` (UIKit-backed)
/// and recomputes the `LayoutDocument` whenever the score, staff size, or
/// container width changes. Holding the document on this view (instead
/// of letting `ScoreView`'s convenience init re-run layout each pass)
/// keeps re-layout cost confined to real input changes — and makes the
/// document available to a future `ScoreHitTester` without rebuilding.
///
/// Drives playback auto-scroll: when `playbackCursor` moves outside the
/// viewport in either axis, an animated scroll command brings the
/// cursor's frame back inside with a small padding inset. Horizontal
/// follow only kicks in once `viewportZoom` makes the content wider than
/// the viewport — at zoom 1.0 the score wraps to fit and X never moves.
///
/// Owns the pinch / double-tap zoom gestures. The score content is
/// `scaleEffect`-ed *inside* the scroll host (with an explicit scaled
/// `.frame`) so the underlying `UIScrollView` is never zoomed — its
/// `maximumZoomScale` is pinned at 1 and it scrolls the zoomed extent
/// natively. That keeps the SwiftUI `Canvas` re-rasterising under
/// `scaleEffect` (sharp throughout the pinch) instead of falling back
/// to a `CALayer` bitmap upscale.
///
/// During a live pinch, two `scaleEffect`s compose:
///   * inner `liveMagnification` with `anchor: liveMagAnchor` (the gesture
///     start anchor reported by the host's `UIPinchGestureRecognizer`) —
///     pivots the visual around the user's fingers without changing
///     layout;
///   * outer committed `viewportZoom` with `anchor: .topLeading` — the
///     persistent scale that drives the `.frame` size and the scroll
///     view's scrollable extent.
/// On gesture end the live factor is folded into `viewportZoom` and a
/// scroll command is queued so the pinch's content point stays under the
/// same viewport coord — equivalent to UIScrollView's `viewForZooming`
/// behaviour but driven from SwiftUI state so resolution doesn't drop.
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    /// Scroll target queued at pinch-end to be applied once
    /// `viewportZoom`'s state change has propagated to a new framed
    /// `intrinsicContentSize` (and therefore a new `UIScrollView.contentSize`).
    /// Applying the offset in the same transaction as a `viewportZoom`
    /// change clamps it to the *old* `maxScroll`, so for zoom-in the
    /// anchor lands ~`(framedHeight_pre - framedHeight_post)/2` below the
    /// user's pinch — visible as a "1-staff drift down."
    @State private var pendingPinchScroll: CGPoint?
    /// Programmatic scroll command consumed by `ScoreScrollHost`. The
    /// host applies the offset on the next `updateUIView` and clears
    /// the binding.
    @State private var pendingScroll: ScoreScrollCommand?
    /// `UIScrollView.adjustedContentInset.top` — kept around for any
    /// cursor-frame math that needs to know how much of the viewport
    /// is hidden behind nav chrome. The pinch commit math itself is
    /// expressed in `contentOffset` units (which already account for
    /// inset), so we don't add this back any more.
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

    /// Captured at `onPinchBegan` so the gesture-end commit knows the
    /// zoom that was in effect at the start of the pinch (independent
    /// of any concurrent state mutation).
    private struct PinchSession {
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
                    honorLayoutBreaks: honorLayoutBreaks,
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
        }
    }

    private func scrollContent(viewport: CGSize) -> some View {
        ScoreScrollHost(
            contentOffset: $liveScrollOffset,
            contentInsetTop: $contentInsetTop,
            pendingScroll: $pendingScroll,
            onPinchBegan: { anchor, _ in
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
                liveMagAnchor = anchor
                liveMagnification = 1.0
            },
            onPinchChanged: { magnification in
                liveMagnification = magnification
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
        .onChange(of: viewModel.viewportZoom) { _, _ in
            // After a pinch zoom commit, apply the queued scroll once
            // the new `viewportZoom` has produced a new framed size
            // (and therefore a new `UIScrollView.contentSize`).
            // Applying it in the same transaction would clamp the
            // offset to the old `maxScroll`.
            if let target = pendingPinchScroll {
                pendingPinchScroll = nil
                pendingScroll = .immediate(target)
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
                    alignment: .topLeading,
                )
                .simultaneousGesture(doubleTapGesture)
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
        for doc: LayoutDocument, viewport: CGSize,
    ) -> CGFloat {
        let fit = doc.size.width > 0
            ? min(1.0, viewport.width / doc.size.width)
            : 1.0
        return viewModel.viewportZoom * fit
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

            if viewModel.repeatMode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.abRepeat)
                LoopBoundaryMarkers(
                    document: doc,
                    start: viewModel.pendingRepeatA,
                    end: viewModel.pendingRepeatB,
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

    /// Folds a finished pinch into `viewportZoom` and queues a scroll
    /// command so the content point under the user's fingers at
    /// release lands on the same screen position post-commit.
    ///
    /// `currentOffset` is the scroll view's `contentOffset` at the
    /// moment the gesture ended — using the *current* offset (instead
    /// of the offset captured at pinch-start, as the SwiftUI version
    /// did) preserves any pan that happened during the pinch:
    ///
    /// ```
    /// pre-commit screen pos  = startLocation - currentOffset
    /// post-commit screen pos = startLocation * ratio - newOffset
    /// ⇒ newOffset = startLocation * (ratio - 1) + currentOffset
    /// ```
    ///
    /// When pan-during-pinch is zero this collapses to the original
    /// SwiftUI formula.
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
            y: max(0, currentOffset.y + startLocation.y * (ratio - 1)),
        )

        let isBounceBack = targetZoom <= 1.0 && session.baseZoom <= 1.0
        if isBounceBack {
            // Rubber-band release: user pinched below 1.0 from a
            // baseline of 1.0. No actual zoom or scroll commit — just
            // animate the inner `liveMagnification` back to identity
            // so the visual snap from compressed back to layout is a
            // smooth motion (matches `UIScrollView`'s bounce feel)
            // instead of an abrupt jump that pulls content away from
            // the anchor.
            //
            // Important: keep `liveMagAnchor` at the gesture's start
            // anchor for the duration of the animation. Animating it
            // toward `.center` would interpolate the scale pivot
            // mid-bounce, sliding the content visibly toward the
            // frame center — visible as "judder". At `mag = 1.0` the
            // anchor is irrelevant so we just leave the stale value
            // behind; the next pinch's `onPinchBegan` overwrites it.
            withAnimation(.smooth(duration: 0.15)) {
                liveMagnification = 1.0
            }
        } else {
            // Real zoom commit (in or out from a non-unit base). Queue
            // the scroll target — the `onChange(of: viewportZoom)`
            // handler applies it once the framed size has propagated
            // to the scroll host's `contentSize`, so the offset isn't
            // clamped to the pre-zoom `maxScroll`. `viewportZoom`,
            // `liveMagnification`, and `liveMagAnchor` still commit
            // atomically here so outer-scale grows by `ratio` while
            // inner-scale drops to identity in the same render — no
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

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                viewModel.toggleZoom(targetIfZoomedOut: 2.0)
            }
    }

    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: true, includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false,
        )
    }

    private func rebuildLayout(width: CGFloat) {
        document = LayoutEngine.layout(
            score: score, options: scoreOptions, availableWidth: width,
        )
        lastWidth = width
    }

    private func autoScroll(
        cursor: ScoreCursor?,
        viewport: CGSize,
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
    /// the viewport with `pad` margin. Returns `currentOffset` unchanged
    /// when the target is already fully visible — preserves manual
    /// horizontal panning while playback advances within the visible row.
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

    /// Hashable composite key so `.task(id:)` re-runs only when one of
    /// the inputs to layout actually changes.
    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool

        init(score: Score, size: CGFloat, width: CGFloat, honorLayoutBreaks: Bool) {
            // `Score` is Equatable but not Hashable. Use a cheap
            // identity proxy: structural shape + opening clefs. The
            // opening-clef hash is what makes a clef override (a
            // field-level edit that leaves parts.count / staff count
            // unchanged) re-trigger this `.task(id:)`.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
        }
    }
}

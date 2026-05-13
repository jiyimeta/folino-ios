// swiftlint:disable file_length
import Domain
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
///   * inner `pinch.magnification` with `anchor: pinch.anchor` (the
///     gesture start anchor reported by the host's
///     `UIPinchGestureRecognizer`) — pivots the visual around the
///     user's fingers without changing layout;
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
    let collapseMultiMeasureRests: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?
    /// Programmatic scroll command consumed by `ScoreScrollHost`. The
    /// host applies the offset synchronously inside `updateUIView`
    /// (after forcing `layoutIfNeeded()` so the new `contentSize`
    /// derived from `viewportZoom` is in place) and clears the binding
    /// on the next runloop tick.
    @State private var pendingScroll: ScoreScrollCommand?
    /// `UIScrollView.adjustedContentInset.top` — kept around for any
    /// cursor-frame math that needs to know how much of the viewport
    /// is hidden behind nav chrome. The pinch commit math itself is
    /// expressed in `contentOffset` units (which already account for
    /// inset), so we don't add this back any more.
    @State private var contentInsetTop: CGFloat = 0
    /// System top safe-area inset (status bar / notch). Parent
    /// `ReaderRootScreen`'s `.safeAreaPadding(.top, ReaderTopOverlay.height)`
    /// augmentation is subtracted back out below, so this carries the
    /// system value only.
    @State private var safeAreaTop: CGFloat = 0
    /// Live pinch state, held as an `@Observable` reference so
    /// mutations propagate into the hosted score subtree via SwiftUI
    /// observation — not through `ScoreScrollHost.updateUIView`'s
    /// `rootView` reassignment, which drops the animation transaction
    /// set by `withAnimation { … }`. See `PinchState`'s docblock.
    /// The container's body does not read `pinch.*` directly; only
    /// `VerticalZoomedSurface` does.
    @State private var pinch = PinchState()

    /// Vertical padding that lives inside the scaled content so the
    /// first / last system don't butt up against the viewport edges.
    /// Scales with the score because it's applied inside the
    /// `scaleEffect`. No horizontal counterpart: at zoom 1.0 we want the
    /// score to span the full viewport width edge-to-edge.
    ///
    /// Top is larger than bottom so the first system clears the nav
    /// chrome / safe area when `ignoresSafeArea()` lets the score slide
    /// underneath.
    private let scoreTopPadding: CGFloat = 44
    private let scoreBottomPadding: CGFloat = 16

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
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
        }
        .background {
            // Sibling reader extending beyond safe area (the main GR
            // sits inside it and reports zero). Subtracts the parent
            // overlay augmentation to leave just the system inset.
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
            onPinchBegan: { anchor, _ in
                pinchSession = PinchSession(baseZoom: viewModel.viewportZoom)
                pinch.anchor = anchor
                pinch.magnification = 1.0
                pinch.offsetX = 0
            },
            onPinchChanged: { magnification, translation in
                // Y is fed back through `UIScrollView.contentOffset`
                // natively; only X needs a live offset (no horizontal
                // scrollable extent at user-zoom 1.0).
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
                onDoubleTap: { viewModel.toggleZoom(targetIfZoomedOut: 2.0) },
            )
        }
        // `UIViewRepresentable` resolves safe area by shrinking its UIView
        // frame (SwiftUI's own `ScrollView` keeps the background full-bleed
        // and represents safe area as `contentInsets` — we can't). The
        // overlays sit in a ZStack on top, so letting the score slide
        // under them is the intended look.
        .ignoresSafeArea()
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
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

    /// Folds a finished pinch into `viewportZoom` and queues a scroll
    /// so the content under the user's fingers at release lands on the
    /// same screen position post-commit. Vertical pan-during-pinch rides
    /// on `currentOffset` (UIScrollView native); horizontal rides on
    /// `pinch.offsetX`.
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
            // Rubber-band release: user pinched below 1.0 from a
            // baseline of 1.0. No actual zoom or scroll commit — just
            // animate the inner `pinch.magnification` back to identity
            // so the visual snap from compressed back to layout is a
            // smooth motion (matches `UIScrollView`'s bounce feel)
            // instead of an abrupt jump that pulls content away from
            // the anchor.
            //
            // Important: keep `pinch.anchor` at the gesture's start
            // anchor for the duration of the animation. Animating it
            // toward `.center` would interpolate the scale pivot
            // mid-bounce, sliding the content visibly toward the
            // frame center — visible as "judder". At `magnification = 1.0`
            // the anchor is irrelevant so we just leave the stale value
            // behind; the next pinch's `onPinchBegan` overwrites it.
            withAnimation(.smooth(duration: 0.18)) {
                pinch.magnification = 1.0
                pinch.offsetX = 0
            }
        } else {
            pendingScroll = .immediate(scrollToTarget)
            let snapToUnit = targetZoom <= 1.0
            if snapToUnit {
                // Snap-to-unit from a non-unit base: visible scale
                // genuinely changes (`combined < 1.0 → 1.0`), so
                // animate every state mutation together so the user
                // sees a smooth settle to identity.
                withAnimation(.smooth(duration: 0.18)) {
                    viewModel.resetZoom()
                    pinch.magnification = 1.0
                    pinch.anchor = .center
                    pinch.offsetX = 0
                }
            } else {
                // Real zoom-in / zoom-out. See HorizontalScoreContainer
                // for the rationale: combined visible scale is
                // invariant across the commit (`baseZoom × gr.scale
                // = targetZoom × 1.0`); interpolating each factor
                // separately would make their product bulge along the
                // easing curve and read as an unwanted scale animation.
                // Snap the scale state, animate only the live offset
                // reset, and only when the scroll view can't absorb it.
                //
                // `postFramedWidth = min(doc.width, viewport.width) *
                // targetZoom` mirrors `effectiveZoom`'s fit-to-width
                // shrink: at `viewportZoom == 1.0` the score wraps to
                // viewport width, and zooming in scales that fit width.
                viewModel.viewportZoom = targetZoom
                viewModel.captureCurrentZoomAsLast()
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
        )
    }

    /// Runs `LayoutEngine.layout` off the main actor so a heavy re-layout
    /// (staff hide/show, clef override, staff-size change) doesn't stall
    /// the UI. The `.task(id:)` wrapper cancels the outer task on the next
    /// input change; we honor that here before publishing a stale document.
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

        // Mirror `zoomedSurface`'s effective scale (user zoom × fit-to-width)
        // so cursor-frame coordinates match the rendered scroll-content size.
        let zoom = effectiveZoom(for: doc, viewport: viewport)
        let pad = 8 * doc.metrics.sp * zoom

        // Cursor frame in scroll-content coords: vertical padding only,
        // then scaled from top-leading. Mirrors `zoomedSurface`'s
        // composition (no horizontal padding).
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
}

/// The hosted score subtree. Lives inside `ScoreScrollHost`'s
/// `UIHostingController`. Reads `pinch.*` and `viewModel.viewportZoom`
/// directly so the SwiftUI observation system can deliver animated
/// updates inside the host (the parent `VerticalScoreContainer` body
/// never touches these properties, so it doesn't re-render and the
/// hostingController doesn't reassign its `rootView` on every gesture
/// frame).
private struct VerticalZoomedSurface: View {
    @Bindable var viewModel: ReaderViewModel
    @Bindable var pinch: PinchState
    let document: LayoutDocument?
    let score: Score
    let viewport: CGSize
    let scoreTopPadding: CGFloat
    let scoreBottomPadding: CGFloat
    let safeAreaTop: CGFloat
    let scoreOptions: ScoreViewOptions
    let playbackCursor: ScoreCursor?
    @Binding var lastManualCursor: ScoreCursor?
    let onDoubleTap: () -> Void

    var body: some View {
        if let doc = document {
            let zoom = effectiveZoom(for: doc)
            let topPad = scoreTopPadding + safeAreaTop
            let framedWidth = doc.size.width * zoom
            let framedHeight = (doc.size.height + topPad + scoreBottomPadding) * zoom
            scoreSurface(document: doc)
                .padding(.top, topPad)
                .padding(.bottom, scoreBottomPadding)
                .scaleEffect(pinch.magnification, anchor: pinch.anchor)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: pinch.offsetX, y: 0)
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

    private func effectiveZoom(for doc: LayoutDocument) -> CGFloat {
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

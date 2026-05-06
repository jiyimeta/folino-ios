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
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var lastManualCursor: ScoreCursor?
    @State private var scrollPosition = ScrollPosition()
    @State private var liveScrollOffset: CGPoint = .zero
    @State private var pinchSession: PinchSession?

    @GestureState private var liveMagnification: CGFloat = 1.0
    @GestureState private var liveMagAnchor: UnitPoint = .center

    /// Padding that lives inside the scaled content so it scales with
    /// the score. Held as an explicit constant (rather than `.padding()`'s
    /// platform default) because the outer `.frame` math needs to know it.
    private let scorePadding: CGFloat = 16

    /// Captured at the first `onChanged` of a pinch so the gesture-end
    /// commit can shift `ScrollPosition` by `start * (mag - 1)` without
    /// fighting any user scrolling that happens during the gesture.
    private struct PinchSession {
        var initialScrollOffset: CGPoint
        var baseZoom: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            scrollContent(viewport: proxy.size)
                .task(id: TaskKey(
                    score: score, size: staffSize,
                    width: max(proxy.size.width, staffSize * 4)
                )) {
                    await rebuildLayout(width: max(proxy.size.width, staffSize * 4))
                }
        }
    }

    @ViewBuilder
    private func scrollContent(viewport: CGSize) -> some View {
        ScrollView([.vertical, .horizontal]) {
            zoomedSurface
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: CGPoint(
                                x: -g.frame(in: .named("vScroll")).origin.x,
                                y: -g.frame(in: .named("vScroll")).origin.y
                            )
                        )
                    }
                )
        }
        .coordinateSpace(name: "vScroll")
        .scrollPosition($scrollPosition, anchor: .topLeading)
        .simultaneousGesture(doubleTapGesture)
        .onPreferenceChange(ScrollOffsetKey.self) { offset in
            liveScrollOffset = offset
        }
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
    }

    @ViewBuilder
    private var zoomedSurface: some View {
        if let doc = document {
            let zoom = viewModel.viewportZoom
            let framedWidth = (doc.size.width + 2 * scorePadding) * zoom
            let framedHeight = (doc.size.height + 2 * scorePadding) * zoom
            scoreSurface(document: doc)
                .padding(scorePadding)
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
            .updating($liveMagnification) { value, state, _ in
                state = value.magnification
            }
            .updating($liveMagAnchor) { value, state, _ in
                state = value.startAnchor
            }
            .onChanged { _ in
                if pinchSession == nil {
                    pinchSession = PinchSession(
                        initialScrollOffset: liveScrollOffset,
                        baseZoom: viewModel.viewportZoom
                    )
                }
            }
            .onEnded { value in
                let session = pinchSession ?? PinchSession(
                    initialScrollOffset: liveScrollOffset,
                    baseZoom: viewModel.viewportZoom
                )
                pinchSession = nil

                let mag = value.magnification
                let combined = session.baseZoom * mag

                if combined < 1.05 {
                    viewModel.resetZoom()
                    scrollPosition.scrollTo(point: .zero)
                } else {
                    viewModel.viewportZoom = combined
                    viewModel.captureCurrentZoomAsLast()
                    // Shift scroll offset so the framed pinch point at
                    // `startLocation * baseZoom` (pre-commit) becomes
                    // `startLocation * combined` (post-commit) while
                    // staying at the same viewport coord. Net delta:
                    // `startLocation * (mag - 1)`.
                    let p = value.startLocation
                    let shifted = CGPoint(
                        x: session.initialScrollOffset.x + p.x * (mag - 1),
                        y: session.initialScrollOffset.y + p.y * (mag - 1)
                    )
                    scrollPosition.scrollTo(point: shifted)
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
            includeTitleFrame: true
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

        let zoom = viewModel.viewportZoom
        let pad = 8 * doc.metrics.sp * zoom

        // Cursor frame in scroll-content coords: padded then scaled from
        // top-leading. Mirrors `zoomedSurface`'s composition.
        let minX = (rect.minX + scorePadding) * zoom
        let maxX = (rect.maxX + scorePadding) * zoom
        let minY = (rect.minY + scorePadding) * zoom
        let maxY = (rect.maxY + scorePadding) * zoom

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

        init(score: Score, size: CGFloat, width: CGFloat) {
            // `Score` is Equatable but not Hashable. Use a cheap
            // identity proxy: parts.count + total staves + division.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
            self.size = size
            self.width = width
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

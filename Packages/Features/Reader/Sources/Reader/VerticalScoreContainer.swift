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
/// Also drives playback auto-scroll: when `playbackCursor` moves into a
/// system that isn't fully visible in the named scroll-view coord space
/// (`"vScroll"`), `ScrollViewReader.scrollTo(_, anchor:)` snaps the
/// system to the nearest viewport edge with a small padding inset.
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0
    @State private var systemFrames: [Int: CGRect] = [:]
    @State private var lastManualCursor: ScoreCursor?
    @GestureState private var seekProbeLocation: CGPoint?

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
        ScrollViewReader { scrollProxy in
            ScrollView([.vertical, .horizontal]) {
                scoreSurface
                    .padding()
            }
            .coordinateSpace(name: "vScroll")
            .onPreferenceChange(VerticalSystemFramesKey.self) { frames in
                systemFrames = frames
            }
            .onChange(of: playbackCursor) { _, newCursor in
                autoScroll(
                    cursor: newCursor, viewport: viewport, proxy: scrollProxy
                )
            }
        }
    }

    @ViewBuilder
    private var scoreSurface: some View {
        if let doc = document {
            ZStack(alignment: .topLeading) {
                ScoreView(
                    document: doc, score: score,
                    playbackCursor: playbackCursor
                )
                VerticalSystemAnchors(document: doc)
            }
            .coordinateSpace(name: "scoreSurface")
            .gesture(longPressSeekGesture(document: doc))
            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)
        } else {
            Color.clear
        }
    }

    private func longPressSeekGesture(document: LayoutDocument) -> some Gesture {
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named("scoreSurface"))
            .updating($seekProbeLocation) { value, state, _ in
                state = value.location
            }
        let longPress = LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .onEnded { _ in
                guard let probe = seekProbeLocation,
                      let cursor = nearestCursor(at: probe, in: document)
                else { return }
                viewModel.setManualCursor(cursor)
                lastManualCursor = cursor
            }
        return drag.simultaneously(with: longPress)
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
        viewport: CGSize,
        proxy: ScrollViewProxy
    ) {
        guard let cursor, let doc = document,
              let sys = doc.systemIndex(forMeasureIndex: cursor.measureIndex),
              let frame = systemFrames[sys]
        else { return }
        if isAnchorFullyVisible(
            anchorMin: frame.minY, anchorMax: frame.maxY,
            anchorSize: frame.height, viewportSize: viewport.height
        ) { return }
        let pad: CGFloat = 8 * doc.metrics.sp
        let unit = paddedScrollAnchor(
            aboveViewport: frame.minY < 0,
            anchorSize: frame.height,
            viewportSize: viewport.height,
            pad: pad
        )
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(VerticalSystemAnchorID(systemIndex: sys), anchor: unit)
        }
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

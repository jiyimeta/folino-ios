import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Wraps `ScoreView(document:score:)` in a horizontal `ScrollView`
/// that lays the score out at its natural width — no system wrapping.
/// Modeled after `SheetMusicExample`'s iOS horizontal mode: the user
/// scrolls one long row of measures, and `HorizontalMeasureAnchors`
/// reports each measure's live frame so playback auto-scroll can ask
/// "is the cursor's measure on screen?" without doing scroll-offset
/// math.
///
/// Tap-to-seek mirrors `VerticalScoreContainer` — `nearestCursor`
/// resolves the touch to a chord/rest cursor and the view model
/// drives playback to land there.
struct HorizontalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel

    @State private var document: LayoutDocument?
    @State private var measureFrames: [Int: CGRect] = [:]
    @State private var lastManualCursor: ScoreCursor?

    private let scorePadding: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal) {
                    // Pin the leading edge so the score doesn't open
                    // half-way across the page. See `VerticalScoreContainer`
                    // for the fuller diagnosis — same root cause: the
                    // ScrollView's content grows from `nil` to the full
                    // natural width once `rebuildLayout` finishes, and the
                    // default anchor preserves the *centre* across that
                    // change.
                    if let doc = document {
                        ZStack(alignment: .topLeading) {
                            ScoreView(
                                document: doc, score: score, options: scoreOptions,
                                playbackCursor: playbackCursor,
                                playbackCursorColor: .accentColor
                            )
                            .coordinateSpace(name: "scoreSurface")
                            .gesture(tapSeekGesture(document: doc))
                            .sensoryFeedback(.impact(weight: .medium), trigger: lastManualCursor)
                            HorizontalMeasureAnchors(document: doc)
                        }
                        .frame(minHeight: proxy.size.height)
                        .padding(scorePadding)
                    }
                }
                .defaultScrollAnchor(.leading)
                .coordinateSpace(name: "hScroll")
                .onPreferenceChange(HorizontalMeasureFramesKey.self) { frames in
                    measureFrames = frames
                }
                .onChange(of: playbackCursor) { _, newCursor in
                    autoScroll(
                        cursor: newCursor,
                        viewport: proxy.size,
                        proxy: scrollProxy
                    )
                }
            }
            .task(id: TaskKey(
                score: score, size: staffSize,
                honorLayoutBreaks: honorLayoutBreaks
            )) {
                rebuildLayout()
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

    // Horizontal mode: lay out at natural content width so systems
    // never wrap. Title frame is omitted — it'd push the score
    // down inside what is essentially a single long row.
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false
        )
    }

    private func rebuildLayout() {
        let opts = scoreOptions
        let natural = LayoutEngine.naturalContentWidth(score: score, options: opts)
        document = LayoutEngine.layout(score: score, options: opts, availableWidth: natural)
    }

    private func autoScroll(
        cursor: ScoreCursor?,
        viewport: CGSize,
        proxy: ScrollViewProxy
    ) {
        guard viewModel.isPlaying,
              let cursor, let doc = document
        else { return }
        let mi = cursor.measureIndex
        guard let frame = measureFrames[mi] else { return }
        if isAnchorFullyVisible(
            anchorMin: frame.minX, anchorMax: frame.maxX,
            anchorSize: frame.width,
            viewportSize: viewport.width
        ) { return }

        // Both off-right (cursor overflowing the trailing edge) and
        // off-left (cursor lagging behind the leading edge) snap to a
        // padded leading anchor — keeps a small inset so the measure
        // isn't jammed flush against the viewport's leading edge, and
        // off-right gets a full row of upcoming measures to read into.
        let pad: CGFloat = 8 * doc.metrics.sp
        let unit = paddedScrollAnchor(
            aboveViewport: true,
            anchorSize: frame.width,
            viewportSize: viewport.width,
            pad: pad,
            horizontal: true
        )
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(
                HorizontalMeasureAnchorID(measureIndex: mi),
                anchor: unit
            )
        }
    }

    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let honorLayoutBreaks: Bool

        init(score: Score, size: CGFloat, honorLayoutBreaks: Bool) {
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
            self.size = size
            self.honorLayoutBreaks = honorLayoutBreaks
        }
    }
}

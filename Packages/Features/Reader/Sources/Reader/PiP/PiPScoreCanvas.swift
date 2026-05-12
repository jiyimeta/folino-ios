import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Off-screen layout of a horizontal score for PiP rendering.
/// Uses the same LayoutEngine calls as `HorizontalScoreContainer`,
/// but skips the ScrollView, tap-to-seek, and overlay markers — PiP
/// is read-only display.
struct PiPScoreCanvas: View {
    let score: Score
    let staffSize: CGFloat
    let playbackCursor: ScoreCursor?

    private static let leadingInset: CGFloat = 80

    var body: some View {
        let opts = ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: .ignoreAll,
            showBreakIndicators: false,
        )
        let naturalWidth = LayoutEngine.naturalContentWidth(score: score, options: opts)
        let document = LayoutEngine.layout(
            score: score, options: opts, availableWidth: naturalWidth,
        )
        ScoreView(
            document: document, score: score, options: opts,
            playbackCursor: playbackCursor,
            playbackCursorColor: .accentColor,
        )
        .offset(x: cursorOffsetX(document: document))
    }

    private func cursorOffsetX(document: LayoutDocument) -> CGFloat {
        guard let cursor = playbackCursor,
              let system = document.systems.first,
              let measure = system.measures.first(where: {
                  $0.measureIndex == cursor.measureIndex
              })
        else { return 0 }
        let measureDocX = system.origin.x + measure.origin.x
        return -measureDocX + Self.leadingInset
    }
}

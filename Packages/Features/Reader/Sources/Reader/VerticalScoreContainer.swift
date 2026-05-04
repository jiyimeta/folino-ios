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
struct VerticalScoreContainer: View {
    let score: Score
    let staffSize: CGFloat

    @State private var document: LayoutDocument?
    @State private var lastWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, staffSize * 4)
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if let doc = document {
                        ScoreView(document: doc, score: score)
                    } else {
                        Color.clear
                    }
                }
                .padding()
            }
            .task(id: TaskKey(score: score, size: staffSize, width: width)) {
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
            // That's enough to detect "different score loaded"
            // without paying for a full hash.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
            self.size = size
            self.width = width
        }
    }
}

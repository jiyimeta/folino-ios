import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

struct ScoreFileSummaryFromScoreTests {
    @Test func `summary extracts credit metaTags`() {
        let score = Score(
            division: 480,
            metaTags: [
                "composer": "Beethoven",
                "arranger": "Liszt",
                "lyricist": "Schiller",
                "copyright": "© 1824",
            ],
        )
        let summary = ScoreFileSummary(score: score)
        #expect(summary.composer == "Beethoven")
        #expect(summary.arranger == "Liszt")
        #expect(summary.lyricist == "Schiller")
        #expect(summary.copyright == "© 1824")
    }

    @Test func `summary leaves missing credit metaTags nil`() {
        let summary = ScoreFileSummary(score: Score(division: 480))
        #expect(summary.arranger == nil)
        #expect(summary.lyricist == nil)
        #expect(summary.copyright == nil)
    }
}

import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

struct ScoreFileMetadataFromScoreTests {
    @Test func `maps museScore v4 source and credit metaTags`() {
        let score = Score(
            division: 480,
            metaTags: ["composer": "C", "arranger": "A", "lyricist": "L", "copyright": "©"],
            source: .museScore(.v4),
        )
        let meta = ScoreFileMetadata(score: score)
        #expect(meta.source == .museScore(majorVersion: 4))
        #expect(meta.composer == "C")
        #expect(meta.arranger == "A")
        #expect(meta.lyricist == "L")
        #expect(meta.copyright == "©")
    }

    @Test func `maps each source kind`() {
        #expect(
            ScoreFileMetadata(score: Score(division: 1, source: .museScore(.v3))).source == .museScore(majorVersion: 3),
        )
        #expect(
            ScoreFileMetadata(score: Score(division: 1, source: .museScore(.v2))).source == .museScore(majorVersion: 2),
        )
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .musicXML)).source == .musicXML)
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .midi)).source == .midi)
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .pdf)).source == .pdf)
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .unknown)).source == .unknown)
    }
}

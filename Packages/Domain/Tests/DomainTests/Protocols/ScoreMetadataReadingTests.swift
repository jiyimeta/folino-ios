@testable import Domain
import Foundation
import Testing

struct ScoreMetadataReadingTests {
    @Test func `metadata value type stores its fields`() {
        let meta = ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: "C",
            arranger: "A",
            lyricist: "L",
            copyright: "©",
        )
        #expect(meta.source == .museScore(majorVersion: 4))
        #expect(meta.composer == "C")
        #expect(meta.arranger == "A")
        #expect(meta.lyricist == "L")
        #expect(meta.copyright == "©")
    }

    @Test func `source kinds are equatable`() {
        #expect(ScoreSourceKind.midi == .midi)
        #expect(ScoreSourceKind.museScore(majorVersion: 3) != .museScore(majorVersion: 4))
    }
}

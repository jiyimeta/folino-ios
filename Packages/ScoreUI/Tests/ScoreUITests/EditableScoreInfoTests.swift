import Domain
import Foundation
@testable import ScoreUI
import Testing

struct EditableScoreInfoTests {
    private func makeItem(
        composer: String? = nil,
        arranger: String? = nil,
        subtitle: String? = nil,
    ) -> ScoreItem {
        ScoreItem(
            title: "Title", subtitle: subtitle, composer: composer, arranger: arranger,
            lyricist: nil, copyright: nil, instrumentationSummary: nil,
            localFileName: "x.mscz", contentHash: String(repeating: "0", count: 64),
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: nil,
            tagIDs: [], isFavorite: false,
        )
    }

    private func meta(composer: String?) -> ScoreFileMetadata {
        ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: composer, arranger: nil, lyricist: nil, copyright: nil,
        )
    }

    @Test func `stored composer wins over file metadata`() {
        let fields = EditableScoreInfo(item: makeItem(composer: "Stored"), fileMetadata: meta(composer: "File"))
        #expect(fields.composer == "Stored")
    }

    @Test func `nil stored field falls back to file metadata`() {
        let fields = EditableScoreInfo(item: makeItem(composer: nil), fileMetadata: meta(composer: "File"))
        #expect(fields.composer == "File")
    }

    @Test func `explicitly cleared field is not re-filled from file metadata`() {
        // A stored empty string is an explicit user value ("I cleared this"), so it wins over the file's metaTag
        // and the field stays empty rather than falling back to the on-disk value.
        let fields = EditableScoreInfo(item: makeItem(composer: ""), fileMetadata: meta(composer: "File"))
        #expect(fields.composer.isEmpty)
    }

    @Test func `both nil yields empty string`() {
        let fields = EditableScoreInfo(item: makeItem(composer: nil), fileMetadata: meta(composer: nil))
        #expect(fields.composer.isEmpty)
    }

    @Test func `subtitle comes straight from stored value, never file metadata`() {
        let fields = EditableScoreInfo(item: makeItem(subtitle: "Sub"), fileMetadata: meta(composer: "File"))
        #expect(fields.subtitle == "Sub")
    }
}

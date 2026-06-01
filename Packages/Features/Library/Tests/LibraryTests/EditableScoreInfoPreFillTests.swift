import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct EditableScoreInfoPreFillTests {
    private static func item(
        subtitle: String? = nil, composer: String? = nil,
        arranger: String? = nil, lyricist: String? = nil, copyright: String? = nil,
    ) -> ScoreItem {
        var item = ScoreItem(
            title: "T", composer: composer, arranger: arranger, lyricist: lyricist, copyright: copyright,
            instrumentationSummary: nil, localFileName: "x.mscx", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        item.subtitle = subtitle
        return item
    }

    private static func meta(arranger: String?) -> ScoreFileMetadata {
        ScoreFileMetadata(source: .unknown, composer: nil, arranger: arranger, lyricist: nil, copyright: nil)
    }

    @Test func `NULL field is pre-filled from file metadata`() {
        let fields = EditableScoreInfo(item: Self.item(arranger: nil), fileMetadata: Self.meta(arranger: "FromFile"))
        #expect(fields.arranger == "FromFile")
    }

    @Test func `explicitly cleared field is not re-filled`() {
        let fields = EditableScoreInfo(item: Self.item(arranger: ""), fileMetadata: Self.meta(arranger: "FromFile"))
        #expect(fields.arranger.isEmpty)
    }

    @Test func `stored value wins over file metadata`() {
        let item = Self.item(arranger: "Stored")
        let fields = EditableScoreInfo(item: item, fileMetadata: Self.meta(arranger: "FromFile"))
        #expect(fields.arranger == "Stored")
    }

    @Test func `nil metadata falls back to empty strings`() {
        let fields = EditableScoreInfo(item: Self.item(), fileMetadata: nil)
        #expect(fields.title == "T")
        #expect(fields.arranger.isEmpty)
        #expect(fields.composer.isEmpty)
    }
}

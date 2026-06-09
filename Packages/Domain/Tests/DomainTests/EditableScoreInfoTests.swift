import Domain
import Foundation
import Testing

struct EditableScoreInfoTests {
    @Test func `prefill stored value wins over file metadata`() {
        let meta = ScoreFileMetadata(
            source: .unknown,
            composer: "File",
            arranger: "FileArr",
            lyricist: "FileLyr",
            copyright: "FileCopy",
        )
        let info = EditableScoreInfo.prefilled(
            title: "T", subtitle: "Sub", composer: "Stored",
            arranger: nil, lyricist: "", copyright: nil, fileMetadata: meta,
        )
        #expect(info.composer == "Stored")
        #expect(info.arranger == "FileArr")
        #expect(info.lyricist.isEmpty)
        #expect(info.copyright == "FileCopy")
        #expect(info.subtitle == "Sub")
    }

    @Test func `prefill subtitle has no file fallback`() {
        let meta = ScoreFileMetadata(
            source: .unknown,
            composer: nil,
            arranger: nil,
            lyricist: nil,
            copyright: nil,
        )
        let info = EditableScoreInfo.prefilled(
            title: "T", subtitle: nil, composer: nil,
            arranger: nil, lyricist: nil, copyright: nil, fileMetadata: meta,
        )
        #expect(info.subtitle.isEmpty)
    }

    @Test func `normalized trims all fields`() {
        let info = EditableScoreInfo(
            title: "  T  ",
            subtitle: " s ",
            composer: " c ",
            arranger: " a ",
            lyricist: " l ",
            copyright: " r ",
        )
        let n = info.normalized()
        #expect(n?.title == "T")
        #expect(n?.subtitle == "s")
        #expect(n?.composer == "c")
        #expect(n?.arranger == "a")
        #expect(n?.lyricist == "l")
        #expect(n?.copyright == "r")
    }

    @Test func `normalized returns nil when title blank`() {
        let info = EditableScoreInfo(
            title: "   ",
            subtitle: "x",
            composer: "",
            arranger: "",
            lyricist: "",
            copyright: "",
        )
        #expect(info.normalized() == nil)
    }

    @Test func `init from item falls back to file metadata for nil credits`() {
        let meta = ScoreFileMetadata(
            source: .unknown,
            composer: "FileComposer",
            arranger: nil,
            lyricist: nil,
            copyright: nil,
        )
        let item = ScoreItem(
            title: "Song",
            subtitle: nil,
            composer: nil,
            arranger: nil,
            lyricist: nil,
            copyright: nil,
            instrumentationSummary: nil,
            localFileName: "test.mxl",
            contentHash: "abc123",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        let info = EditableScoreInfo(item: item, fileMetadata: meta)
        #expect(info.title == "Song")
        #expect(info.composer == "FileComposer") // nil stored → file fallback
        #expect(info.subtitle.isEmpty) // subtitle never falls back
    }

    @Test func `normalized keeps cleared fields as empty string`() {
        let info = EditableScoreInfo(
            title: "T",
            subtitle: "",
            composer: "",
            arranger: "",
            lyricist: "",
            copyright: "",
        )
        let n = info.normalized()
        #expect(n?.title == "T")
        #expect(n?.subtitle.isEmpty == true)
        #expect(n?.composer.isEmpty == true)
        #expect(n?.arranger.isEmpty == true)
        #expect(n?.lyricist.isEmpty == true)
        #expect(n?.copyright.isEmpty == true)
    }
}

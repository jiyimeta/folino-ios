@testable import Domain
import Testing
import UtilityCore

struct AnalyticsLibrarySnapshotTests {
    @Test func `counts by format raw`() {
        let items = [
            makeItem("a.mscz", museScoreMajorVersion: 4),
            makeItem("b.mscz", museScoreMajorVersion: 3),
            makeItem("c.musicxml"),
            makeItem("d.mid"),
            makeItem("e.pdf"),
        ]
        let event = AnalyticsLibrarySnapshot.event(items: items, playlistCount: 2, tagCount: 1)
        #expect(event.name == "library_snapshot")
        #expect(event.parameters["score_count_total"] == .int(5))
        #expect(event.parameters["score_count_mscz4"] == .int(1))
        #expect(event.parameters["score_count_mscz3"] == .int(1))
        #expect(event.parameters["score_count_mscz2"] == .int(0))
        #expect(event.parameters["score_count_musicxml"] == .int(1))
        #expect(event.parameters["score_count_midi"] == .int(1))
        #expect(event.parameters["score_count_pdf"] == .int(1))
        #expect(event.parameters["playlist_count"] == .int(2))
        #expect(event.parameters["tag_count"] == .int(1))
        #expect(event.parameters["favorite_count"] == .int(0))
    }

    @Test func `nil muse score version treated as V 4`() {
        let items = [
            makeItem("a.mscz", museScoreMajorVersion: nil), // nil → v4 default
        ]
        let event = AnalyticsLibrarySnapshot.event(items: items, playlistCount: 0, tagCount: 0)
        #expect(event.parameters["score_count_mscz4"] == .int(1))
        #expect(event.parameters["score_count_mscz3"] == .int(0))
    }

    @Test func `music XML and mxl both counted as music XML`() {
        let items = [
            makeItem("a.musicxml"),
            makeItem("b.mxl"),
        ]
        let event = AnalyticsLibrarySnapshot.event(items: items, playlistCount: 0, tagCount: 0)
        #expect(event.parameters["score_count_musicxml"] == .int(2))
    }

    @Test func `favorites counted correctly`() {
        let items = [
            makeItem("a.mscz", isFavorite: true),
            makeItem("b.mscz", isFavorite: false),
            makeItem("c.musicxml", isFavorite: true),
        ]
        let event = AnalyticsLibrarySnapshot.event(items: items, playlistCount: 0, tagCount: 0)
        #expect(event.parameters["favorite_count"] == .int(2))
    }
}

// MARK: - Fixture

private func makeItem(_ name: String, museScoreMajorVersion: Int? = nil, isFavorite: Bool = false) -> ScoreItem {
    ScoreItem(
        title: "Test",
        composer: nil,
        instrumentationSummary: nil,
        localFileName: name,
        contentHash: "abc123",
        sizeBytes: 0,
        lengthBeats: 0,
        defaultTempoBpm: 120,
        primaryKey: nil,
        addedAt: .distantPast,
        lastOpenedAt: nil,
        tagIDs: [],
        isFavorite: isFavorite,
        museScoreMajorVersion: museScoreMajorVersion,
    )
}

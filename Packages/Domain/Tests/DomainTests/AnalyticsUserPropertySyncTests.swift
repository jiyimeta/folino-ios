@testable import Domain
import Testing
import UtilityCore

private final class RecordingAnalytics: Analytics, @unchecked Sendable {
    var properties: [String: String?] = [:]
    func setCollectionEnabled(_: Bool) {}
    func log(_: AnalyticsEvent) {}
    func setUserProperty(_ value: String?, for property: AnalyticsUserProperty) {
        properties[property.name] = value
    }
}

private func makeItem(localFileName: String, museScoreMajorVersion: Int? = nil) -> ScoreItem {
    ScoreItem(
        title: "Test",
        composer: nil,
        instrumentationSummary: nil,
        localFileName: localFileName,
        contentHash: "abc123",
        sizeBytes: 0,
        lengthBeats: 0,
        defaultTempoBpm: 120,
        primaryKey: nil,
        addedAt: .distantPast,
        lastOpenedAt: nil,
        tagIDs: [],
        isFavorite: false,
        museScoreMajorVersion: museScoreMajorVersion,
    )
}

struct AnalyticsUserPropertySyncTests {
    @Test func `counts scores by format and mscz major`() {
        let items = [
            makeItem(localFileName: "a1.mscz", museScoreMajorVersion: 4),
            makeItem(localFileName: "a2.mscz", museScoreMajorVersion: 4),
            makeItem(localFileName: "a3.mscz", museScoreMajorVersion: 3),
            makeItem(localFileName: "a4.mscz", museScoreMajorVersion: nil), // defaults to v4
            makeItem(localFileName: "b.musicxml"),
            makeItem(localFileName: "c.mid"),
            makeItem(localFileName: "d.pdf"),
        ]
        let rec = RecordingAnalytics()
        AnalyticsUserPropertySync.syncLibrary(items: items, sort: .titleAsc, into: rec)
        // mscz v4: two explicit + one nil-as-v4 = 3
        #expect(rec.properties["score_count_mscz4"] == "1-5")
        #expect(rec.properties["score_count_mscz3"] == "1-5")
        #expect(rec.properties["score_count_mscz2"] == "0")
        #expect(rec.properties["score_count_musicxml"] == "1-5")
        #expect(rec.properties["score_count_midi"] == "1-5")
        // PDF is now counted properly (not hardcoded "0")
        #expect(rec.properties["score_count_pdf"] == "1-5")
        // 7 items total → "6-20"
        #expect(rec.properties["library_size_bucket"] == "6-20")
        #expect(rec.properties["current_sort_order"] == "title")
    }
}

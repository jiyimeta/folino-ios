@testable import Domain
import Testing
import UtilityCore

struct AnalyticsEventFactoryTests {
    @Test func `score imported carries format source duplicate and version`() {
        let event = AnalyticsEvent.scoreImported(
            format: .mscz, source: "file_picker", isDuplicate: false, museScoreMajorVersion: 4,
        )
        #expect(event.name == "score_imported")
        #expect(event.parameters["format"] == .string("mscz"))
        #expect(event.parameters["source"] == .string("file_picker"))
        #expect(event.parameters["is_duplicate"] == .bool(false))
        #expect(event.parameters["musescore_version"] == .string("4"))
    }

    @Test func `score imported without version emits unknown`() {
        let event = AnalyticsEvent.scoreImported(
            format: .musicXML, source: "share_ext", isDuplicate: true, museScoreMajorVersion: nil,
        )
        #expect(event.parameters["musescore_version"] == .string("unknown"))
    }

    @Test func `favorite toggled carries enabled source mode`() {
        let event = AnalyticsEvent.favoriteToggled(enabled: true, source: .scoreRowMenu, mode: .single)
        #expect(event.name == "favorite_toggled")
        #expect(event.parameters["enabled"] == .bool(true))
        #expect(event.parameters["source"] == .string("score_row_menu"))
        #expect(event.parameters["mode"] == .string("single"))
    }

    @Test func `select content uses reserved name with from`() {
        let event = AnalyticsEvent.scoreOpened(from: .playlist)
        #expect(event.name == "select_content")
        #expect(event.parameters["content_type"] == .string("score"))
        #expect(event.parameters["from"] == .string("playlist"))
    }

    @Test func `share uses reserved name`() {
        let event = AnalyticsEvent.share(method: "pdf", source: .bulkEdit, mode: .bulk)
        #expect(event.name == "share")
        #expect(event.parameters["content_type"] == .string("score"))
        #expect(event.parameters["method"] == .string("pdf"))
        #expect(event.parameters["mode"] == .string("bulk"))
    }

    @Test func `count parameters are bucketed not raw`() {
        // Privacy contract: factories must emit a bucketed string, never a raw `.int`.
        #expect(
            AnalyticsEvent.scoreDeleted(source: .bulkEdit, mode: .bulk, count: 3)
                .parameters["count"] == .string("1-5"),
        )
        #expect(
            AnalyticsEvent.scoreAddedToPlaylist(source: .scoreRowMenu, count: 25)
                .parameters["count"] == .string("21-50"),
        )
        #expect(
            AnalyticsEvent.tagAssigned(source: .bulkEdit, count: 0)
                .parameters["count"] == .string("0"),
        )
    }
}

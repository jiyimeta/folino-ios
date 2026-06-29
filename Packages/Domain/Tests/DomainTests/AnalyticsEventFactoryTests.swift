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

    @Test func `scoreDeleted logs raw count`() {
        let event = AnalyticsEvent.scoreDeleted(source: .bulkEdit, mode: .bulk, count: 7)
        #expect(event.name == "score_deleted")
        #expect(event.parameters["count"] == .int(7))
        #expect(event.parameters["source"] == .string("bulk_edit"))
        #expect(event.parameters["mode"] == .string("bulk"))
    }

    @Test func `scoreAddedToPlaylist logs raw count`() {
        let event = AnalyticsEvent.scoreAddedToPlaylist(source: .scoreRowMenu, count: 25)
        #expect(event.name == "score_added_to_playlist")
        #expect(event.parameters["count"] == .int(25))
        #expect(event.parameters["source"] == .string("score_row_menu"))
    }

    @Test func `scoreRemovedFromPlaylist logs raw count`() {
        let event = AnalyticsEvent.scoreRemovedFromPlaylist(source: .bulkEdit, count: 3)
        #expect(event.name == "score_removed_from_playlist")
        #expect(event.parameters["count"] == .int(3))
        #expect(event.parameters["source"] == .string("bulk_edit"))
    }

    @Test func `tagAssigned logs raw count`() {
        let event = AnalyticsEvent.tagAssigned(source: .bulkEdit, count: 0)
        #expect(event.name == "tag_assigned")
        #expect(event.parameters["count"] == .int(0))
        #expect(event.parameters["source"] == .string("bulk_edit"))
    }

    @Test func `tagUnassigned logs raw count`() {
        let event = AnalyticsEvent.tagUnassigned(source: .bulkEdit, count: 12)
        #expect(event.name == "tag_unassigned")
        #expect(event.parameters["count"] == .int(12))
        #expect(event.parameters["source"] == .string("bulk_edit"))
    }
}

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

    @Test func `screen factory`() {
        let event = AnalyticsEvent.screen(.reader)
        #expect(event.name == "screen_view")
        #expect(event.parameters["screen_name"] == .string("reader"))
    }

    @Test func `analyticsSource wire values are stable snake_case`() {
        #expect(AnalyticsSource.searchResult.rawValue == "search_result")
        #expect(AnalyticsSource.scoreRowMenu.rawValue == "score_row_menu")
        #expect(AnalyticsSource.libraryAll.rawValue == "library_all")
        #expect(AnalyticsSource.bulkEdit.rawValue == "bulk_edit")
    }

    @Test func `annotation ended factory`() {
        let event = AnalyticsEvent.annotationEnded(strokes: 12, durationSec: 34.5)
        #expect(event.name == "annotation_ended")
        #expect(event.parameters["ink_strokes"] == .int(12))
        #expect(event.parameters["duration_sec"] == .double(34.5))
    }

    @Test func `library snapshot factory`() {
        let event = AnalyticsEvent.librarySnapshot(
            total: 30, mscz2: 1, mscz3: 2, mscz4: 3, musicXML: 4, midi: 5, pdf: 6,
            playlistCount: 7, tagCount: 8, favoriteCount: 9,
        )
        #expect(event.name == "library_snapshot")
        #expect(event.parameters["score_count_total"] == .int(30))
        #expect(event.parameters["score_count_mscz4"] == .int(3))
        #expect(event.parameters["score_count_pdf"] == .int(6))
        #expect(event.parameters["playlist_count"] == .int(7))
        #expect(event.parameters["favorite_count"] == .int(9))
    }

    @Test func `settings snapshot factory`() {
        let event = AnalyticsEvent.settingsSnapshot(
            metronome: true, pictureInPicture: false, collapseMultiMeasureRests: true,
            showInvisibles: false, keepScreenAwake: true, showSeekBar: true,
            repeatMode: .abLoop, playlistContinuation: .playThrough, a4ReferenceHz: 442,
            layoutMode: .page, crashReportingEnabled: true, soundfontPreset: "lightweight",
        )
        #expect(event.name == "settings_snapshot")
        #expect(event.parameters["metronome_enabled"] == .bool(true))
        #expect(event.parameters["picture_in_picture_enabled"] == .bool(false))
        #expect(event.parameters["collapse_multi_measure_rests"] == .bool(true))
        #expect(event.parameters["show_invisible_elements"] == .bool(false))
        #expect(event.parameters["keep_screen_awake"] == .bool(true))
        #expect(event.parameters["show_seek_bar"] == .bool(true))
        #expect(event.parameters["repeat_mode"] == .string("ab_loop"))
        #expect(event.parameters["playlist_continuation"] == .string("play_through"))
        #expect(event.parameters["a4_reference_hz"] == .double(442))
        #expect(event.parameters["layout_mode"] == .string("page"))
        #expect(event.parameters["crash_reporting_enabled"] == .bool(true))
        #expect(event.parameters["soundfont_preset"] == .string("lightweight"))
    }

    @Test func `companion handoff event carries target outcome and source`() {
        let event = AnalyticsEvent.companionHandoff(
            target: "vocaltuner", outcome: .deepLink, source: .scoreRowMenu,
        )
        #expect(event.name == "companion_handoff")
        #expect(event.parameters["target"] == .string("vocaltuner"))
        #expect(event.parameters["outcome"] == .string("deep_link"))
        #expect(event.parameters["source"] == .string("score_row_menu"))
    }

    @Test func `companion handoff outcome raw values are snake case`() {
        #expect(CompanionHandoffOutcome.deepLink.rawValue == "deep_link")
        #expect(CompanionHandoffOutcome.shareFallback.rawValue == "share_fallback")
        #expect(CompanionHandoffOutcome.appStore.rawValue == "app_store")
        #expect(CompanionHandoffOutcome.failed.rawValue == "failed")
    }
}

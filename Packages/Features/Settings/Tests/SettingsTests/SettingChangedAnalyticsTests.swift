import Domain
@testable import Settings
import Testing
import UtilityCore

/// Verifies the single `SettingChangeLogger` funnel that every Settings control routes through. A SwiftUI
/// `@AppStorage` `onChange` side effect cannot be driven from a value-level unit test (no render), so the contract is
/// pinned at the helper seam: each control hands the logger its stable `SettingKey` and a low-cardinality value, and
/// the logger emits exactly one `setting_changed` event with `key`/`value` wire strings.
@MainActor
struct SettingChangedAnalyticsTests {
    @Test func `bool toggle logs true then false`() {
        let spy = SpyAnalytics()
        let log = SettingChangeLogger(analytics: spy)

        log.log(.metronome, true)
        log.log(.metronome, false)

        let events = spy.events.filter { $0.name == "setting_changed" }
        #expect(events.count == 2)
        #expect(events[0].parameters["key"] == .string("metronome_enabled"))
        #expect(events[0].parameters["value"] == .string("true"))
        #expect(events[1].parameters["key"] == .string("metronome_enabled"))
        #expect(events[1].parameters["value"] == .string("false"))
    }

    @Test func `picker logs stable enum wire value`() {
        let spy = SpyAnalytics()
        let log = SettingChangeLogger(analytics: spy)

        log.log(.layoutMode, value: ReaderLayoutMode.vertical.analyticsValue)
        log.log(.repeatMode, value: RepeatMode.loopAll.analyticsValue)

        #expect(spy.events.contains {
            $0.name == "setting_changed"
                && $0.parameters["key"] == .string("layout_mode")
                && $0.parameters["value"] == .string("vertical")
        })
        #expect(spy.events.contains {
            $0.name == "setting_changed"
                && $0.parameters["key"] == .string("repeat_mode")
                && $0.parameters["value"] == .string("loop_all")
        })
    }

    /// Pins every control's stable wire key so a rename is caught here rather than silently shifting analytics.
    @Test func `setting keys are stable wire strings`() {
        #expect(SettingKey.metronome.rawValue == "metronome_enabled")
        #expect(SettingKey.pictureInPicture.rawValue == "picture_in_picture_enabled")
        #expect(SettingKey.collapseMultiMeasureRests.rawValue == "collapse_multi_measure_rests")
        #expect(SettingKey.showInvisibleElements.rawValue == "show_invisible_elements")
        #expect(SettingKey.keepScreenAwake.rawValue == "keep_screen_awake")
        #expect(SettingKey.showSeekBar.rawValue == "show_seek_bar")
        #expect(SettingKey.repeatMode.rawValue == "repeat_mode")
        #expect(SettingKey.playlistContinuation.rawValue == "playlist_continuation")
        #expect(SettingKey.a4Reference.rawValue == "a4_reference_hz")
        #expect(SettingKey.layoutMode.rawValue == "layout_mode")
        #expect(SettingKey.crashReporting.rawValue == "crash_reporting_enabled")
        #expect(SettingKey.analytics.rawValue == "analytics_enabled")
        #expect(SettingKey.precount.rawValue == "precount_enabled")
        #expect(SettingKey(caseToken: "precount") == .precount)
    }
}

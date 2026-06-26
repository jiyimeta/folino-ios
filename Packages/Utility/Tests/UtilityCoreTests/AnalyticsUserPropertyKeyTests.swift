import Testing
@testable import UtilityCore

struct AnalyticsUserPropertyKeyTests {
    @Test func `key wire names`() {
        #expect(AnalyticsUserProperty.layoutMode.name == "layout_mode")
        #expect(AnalyticsUserProperty.soundfontPreset.name == "soundfont_preset")
        #expect(AnalyticsUserProperty.currentSortOrder.name == "current_sort_order")
        #expect(AnalyticsUserProperty.librarySizeBucket.name == "library_size_bucket")
        #expect(AnalyticsUserProperty.crashReportingEnabled.name == "crash_reporting_enabled")
        #expect(AnalyticsUserProperty.hasUsedAnnotation.name == "has_used_annotation")
        #expect(AnalyticsUserProperty.scoreCountMscz2.name == "score_count_mscz2")
        #expect(AnalyticsUserProperty.scoreCountMscz3.name == "score_count_mscz3")
        #expect(AnalyticsUserProperty.scoreCountMscz4.name == "score_count_mscz4")
        #expect(AnalyticsUserProperty.scoreCountMusicXML.name == "score_count_musicxml")
        #expect(AnalyticsUserProperty.scoreCountMidi.name == "score_count_midi")
        #expect(AnalyticsUserProperty.scoreCountPdf.name == "score_count_pdf")
    }
}

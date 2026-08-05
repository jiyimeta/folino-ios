import Domain
@testable import FolinoLibraryJNI
import Testing

struct AnalyticsBridgeScorePrefsTests {
    private func untouched() -> ReaderPreferences {
        ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
    }

    private func param(_ wire: AnalyticsEventWire, _ key: String) -> AnalyticsParamWire? {
        wire.params.first { $0.key == key }
    }

    @Test func `changed blob builds a score_prefs wire with bucketed width`() {
        let prefs = ReaderPreferencesReducer.setStaffSize(untouched(), 18)
        let json = ReaderPreferencesReducer.encode(prefs)
        let wire = AnalyticsBridge().scorePrefs(prefsJson: json, widthDp: 507, defaultStaffSize: 28)
        #expect(wire.name == "score_prefs")
        #expect(param(wire, "staff_size")?.longValue == 18)
        #expect(param(wire, "screen_width_pt")?.longValue == 430)
    }

    @Test func `untouched blob and invalid json return the skip wire`() {
        let blob = ReaderPreferencesReducer.encode(untouched())
        #expect(AnalyticsBridge().scorePrefs(prefsJson: blob, widthDp: 430, defaultStaffSize: 28).name.isEmpty)
        #expect(AnalyticsBridge().scorePrefs(prefsJson: "not json", widthDp: 430, defaultStaffSize: 28).name.isEmpty)
        #expect(AnalyticsBridge().scorePrefs(prefsJson: "", widthDp: 430, defaultStaffSize: 28).name.isEmpty)
    }

    /// The carry-forward from Task 10. Every score any Android user has ever opened carries a legacy blob whose
    /// `staffSize` is the Reader's *global* default (initial 28), written by an eager seed that has since been
    /// removed. Domain's legacy normalization only demotes the fixed constant `14`, so unless this builder decodes
    /// through `decode(_:defaultStaffSize:)` the whole installed base reports `staff_size` as explicitly configured.
    @Test func `a legacy blob whose staff size equals the global default drops staff_size`() {
        var prefs = ReaderPreferencesReducer.setStaffSize(untouched(), 28)
        prefs = ReaderPreferencesReducer.setTranspose(prefs, 2)
        let wire = AnalyticsBridge()
            .scorePrefs(prefsJson: legacyReaderPreferencesBlob(prefs), widthDp: 430, defaultStaffSize: 28)
        #expect(wire.name == "score_prefs")
        #expect(param(wire, "transpose_semitones")?.longValue == 2)
        #expect(param(wire, "staff_size") == nil)

        // With the seeded staff size the only thing stored, the whole row is untouched and emits no event at all.
        let seedOnly = legacyReaderPreferencesBlob(ReaderPreferencesReducer.setStaffSize(untouched(), 28))
        #expect(AnalyticsBridge().scorePrefs(prefsJson: seedOnly, widthDp: 430, defaultStaffSize: 28).name.isEmpty)
    }

    /// The other direction: a legacy blob that disagrees with the global was a real user choice and must survive.
    @Test func `a legacy blob whose staff size differs from the global default keeps it`() {
        let blob = legacyReaderPreferencesBlob(ReaderPreferencesReducer.setStaffSize(untouched(), 18))
        let wire = AnalyticsBridge().scorePrefs(prefsJson: blob, widthDp: 430, defaultStaffSize: 28)
        #expect(wire.name == "score_prefs")
        #expect(param(wire, "staff_size")?.longValue == 18)
    }

    /// Presence-means-changed, end to end through the wire: an untouched field contributes no parameter, and a set
    /// one does even when its value equals the default. Guards against the marshaling step materializing zeros.
    @Test func `only the fields the user set reach the wire`() {
        var prefs = ReaderPreferencesReducer.setMasterVolume(untouched(), 1.0)
        prefs = ReaderPreferencesReducer.setStaffHidden(prefs, part: 0, staff: 0, hidden: true)
        let wire = AnalyticsBridge()
            .scorePrefs(prefsJson: ReaderPreferencesReducer.encode(prefs), widthDp: 1024, defaultStaffSize: 28)
        #expect(param(wire, "master_volume_pct")?.longValue == 100)
        #expect(param(wire, "hidden_staff_count")?.longValue == 1)
        #expect(param(wire, "screen_width_pt")?.longValue == 1024)
        #expect(wire.params.count == 3)
    }
}

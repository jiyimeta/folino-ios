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

    /// The carry-forward from Task 10, widened by the final review. Every score any Android user has ever opened
    /// carries a legacy blob whose `staffSize` is whatever the *global* staff size was at that moment, written by an
    /// eager seed that has since been removed. Matching it against the current global is not enough — the global is a
    /// user-movable slider — so the analytics builder drops `staff_size` for every legacy blob.
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

    /// The case the "equals the current global" rule got wrong: a user who moved the global slider after opening the
    /// score leaves a legacy blob that matches no default in effect. It is still a seed, not a choice, so it must not
    /// reach the wire — otherwise "param present == the user changed it" is false on Android. The row's other touched
    /// fields still report, and the row does not become event-worthy on the strength of the seed alone.
    @Test func `a legacy blob whose staff size differs from the global default still drops staff_size`() {
        var prefs = ReaderPreferencesReducer.setStaffSize(untouched(), 18)
        prefs = ReaderPreferencesReducer.setTranspose(prefs, 2)
        let wire = AnalyticsBridge()
            .scorePrefs(prefsJson: legacyReaderPreferencesBlob(prefs), widthDp: 430, defaultStaffSize: 28)
        #expect(wire.name == "score_prefs")
        #expect(param(wire, "transpose_semitones")?.longValue == 2)
        #expect(param(wire, "staff_size") == nil)

        let seedOnly = legacyReaderPreferencesBlob(ReaderPreferencesReducer.setStaffSize(untouched(), 18))
        #expect(AnalyticsBridge().scorePrefs(prefsJson: seedOnly, widthDp: 430, defaultStaffSize: 28).name.isEmpty)
    }

    /// The boundary of the rule: once a blob carries the `schemaVersion` marker its `staffSize` is authoritative —
    /// it was written by the post-branch code, where `.some` only ever comes from a user mutation — and is reported
    /// even when it happens to equal the global default.
    @Test func `a v2 blob reports its staff size even when it equals the global default`() {
        let chosen = ReaderPreferencesReducer.encode(ReaderPreferencesReducer.setStaffSize(untouched(), 18))
        let wire = AnalyticsBridge().scorePrefs(prefsJson: chosen, widthDp: 430, defaultStaffSize: 28)
        #expect(wire.name == "score_prefs")
        #expect(param(wire, "staff_size")?.longValue == 18)

        let atDefault = ReaderPreferencesReducer.encode(ReaderPreferencesReducer.setStaffSize(untouched(), 28))
        let atDefaultWire = AnalyticsBridge().scorePrefs(prefsJson: atDefault, widthDp: 430, defaultStaffSize: 28)
        #expect(atDefaultWire.name == "score_prefs")
        #expect(param(atDefaultWire, "staff_size")?.longValue == 28)
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

import Domain
@testable import FolinoLibraryJNI
import Testing

struct ReaderPreferencesReducerTests {
    private func base() -> ReaderPreferences {
        ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
    }

    @Test func `set master volume clamps through init`() {
        let p = ReaderPreferencesReducer.setMasterVolume(base(), 5.0) // above max 3.0
        #expect(p.masterVolume == 3.0)
    }

    @Test func `tempo zero sentinel means no override`() {
        var p = ReaderPreferencesReducer.setTempoMultiplier(base(), 0.0)
        #expect(p.tempoMultiplier == nil)
        p = ReaderPreferencesReducer.setTempoMultiplier(base(), 1.5)
        #expect(p.tempoMultiplier == 1.5)
    }

    @Test func `a 4 zero sentinel means inherit`() {
        var p = ReaderPreferencesReducer.setA4ReferenceHz(base(), 0.0)
        #expect(p.a4ReferenceHz == nil)
        p = ReaderPreferencesReducer.setA4ReferenceHz(base(), 432)
        #expect(p.a4ReferenceHz == 432)
    }

    @Test func `set staff program updates addressed entry only`() {
        let p = ReaderPreferencesReducer.setStaffProgram(base(), part: 0, staff: 1, program: 40)
        #expect(p.stripProgramOverrides[MixerStripID(partIndex: 0, instrumentOrdinal: 0)] == 40)
    }

    @Test func `set staff volume updates addressed entry only`() {
        let p = ReaderPreferencesReducer.setStaffVolume(base(), part: 1, staff: 0, volume: 0.25)
        #expect(p.stripVolumeOverrides[MixerStripID(partIndex: 1, instrumentOrdinal: 0)] == 0.25)
    }

    /// Android's mixer is still addressed per staff, but every staff of a part always drove one channel — so a
    /// write from any of a part's rows (here staff 1) must land on the part's tick-0 strip, and must not fan out
    /// into a second stored entry.
    @Test func `a write from any staff lands on the part's first strip`() {
        let p = ReaderPreferencesReducer.setStaffVolume(base(), part: 1, staff: 1, volume: 0.25)

        #expect(p.stripVolumeOverrides[MixerStripID(partIndex: 1, instrumentOrdinal: 0)] == 0.25)
        #expect(p.stripVolumeOverrides.count == 1)
    }

    @Test func `set staff hidden toggles membership`() {
        let addr = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        var p = ReaderPreferencesReducer.setStaffHidden(base(), part: 1, staff: 0, hidden: true)
        #expect(p.hiddenStaves.contains(addr))
        p = ReaderPreferencesReducer.setStaffHidden(p, part: 1, staff: 0, hidden: false)
        #expect(!p.hiddenStaves.contains(addr))
    }

    @Test func `set clef empty removes override`() {
        var p = ReaderPreferencesReducer.setClef(base(), part: 0, staff: 0, rawType: "F")
        #expect(p.staffClefOverrides[StaffAddress(partIndex: 0, staffIndexInPart: 0)] == "F")
        p = ReaderPreferencesReducer.setClef(p, part: 0, staff: 0, rawType: "")
        #expect(p.staffClefOverrides[StaffAddress(partIndex: 0, staffIndexInPart: 0)] == nil)
    }

    @Test func `transpose clamps to seven semitones`() {
        let p = ReaderPreferencesReducer.setTranspose(base(), 99)
        #expect(p.transposeSemitones == 7)
    }

    @Test func `set staff size clamps`() {
        let p = ReaderPreferencesReducer.setStaffSize(base(), 100)
        #expect(p.staffSize == ReaderPreferences.maxStaffSize)
    }

    @Test func `set honor layout breaks`() {
        let p = ReaderPreferencesReducer.setHonorLayoutBreaks(base(), false)
        #expect(p.honorLayoutBreaks == false)
    }

    @Test func `encode decode round trips`() {
        let p = ReaderPreferencesReducer.setMasterVolume(base(), 1.2)
        let json = ReaderPreferencesReducer.encode(p)
        #expect(!json.isEmpty)
        #expect(ReaderPreferencesReducer.decode(json) == p)
    }

    @Test func `decode empty returns nil`() {
        #expect(ReaderPreferencesReducer.decode("") == nil)
    }

    /// Every mutation re-seats through `ReaderPreferences.init`, so the re-seat is the one place that could quietly
    /// drop a field. It must carry the untouched (`nil`) scalars AND the authored-visibility provenance through —
    /// dropping `hasSeededAuthoredVisibility` would make the next open re-hide staves the user revealed, and
    /// dropping `authoredHiddenStaves` would make `reconcilingAuthoredHidden` re-persist on every open.
    @Test func `reseat carries nil scalars and provenance through`() {
        var p = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        p.authoredHiddenStaves = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
        p.hasSeededAuthoredVisibility = true
        let reseated = ReaderPreferencesReducer.setClef(p, part: 0, staff: 0, rawType: "F")
        #expect(reseated.staffSize == nil)
        #expect(reseated.honorLayoutBreaks == nil)
        #expect(reseated.masterVolume == nil)
        #expect(reseated.transposeSemitones == nil)
        #expect(reseated.authoredHiddenStaves == p.authoredHiddenStaves)
        #expect(reseated.hasSeededAuthoredVisibility)
    }

    /// A Kotlin-side set is always an explicit user action, so it writes `.some` even when the value equals the
    /// default. Only the `clear*` verbs go back to "untouched".
    @Test func `kotlin setters still write explicit values`() {
        let p = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        #expect(ReaderPreferencesReducer.setStaffSize(p, 18).staffSize == 18)
        #expect(ReaderPreferencesReducer.setMasterVolume(p, 1.0).masterVolume == 1.0)
        #expect(ReaderPreferencesReducer.setTranspose(p, 0).transposeSemitones == 0)
    }

    /// Reset affordances mean "I never chose this", matching iOS `MasterVolumeModel.resetValue` /
    /// `TransposeModel.reset`. Writing an explicit default instead would report the score as touched.
    @Test func `clear verbs go back to untouched`() {
        let touched = ReaderPreferencesReducer.setTranspose(
            ReaderPreferencesReducer.setMasterVolume(base(), 0.4), 5,
        )
        #expect(ReaderPreferencesReducer.clearMasterVolume(touched).masterVolume == nil)
        #expect(ReaderPreferencesReducer.clearTranspose(touched).transposeSemitones == nil)
        // Clearing one scalar leaves the other alone.
        #expect(ReaderPreferencesReducer.clearMasterVolume(touched).transposeSemitones == 5)
        #expect(ReaderPreferencesReducer.clearTranspose(touched).masterVolume == 0.4)
    }

    /// iOS's `TempoModel.commitMultiplier` snaps a value visually at 100% back to "no override", so a slider that
    /// stops at 0.9999 doesn't leave one behind — and so the two reset affordances (BPM-readout tap, slider
    /// double-tap), which both route through `onRate(1.0f)`, actually clear. Without the snap Android persists an
    /// explicit 1.0 and reports the score in `score_prefs` as one the user set a tempo on.
    @Test func `a tempo at unity snaps back to untouched`() {
        let touched = ReaderPreferencesReducer.setTempoMultiplier(base(), 1.5)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 1.0).tempoMultiplier == nil)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 0.9999).tempoMultiplier == nil)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 1.004).tempoMultiplier == nil)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 0.0).tempoMultiplier == nil)
        // Outside the snap window a set is still an explicit choice.
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 1.01).tempoMultiplier == 1.01)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 0.5).tempoMultiplier == 0.5)
    }

    /// The staff-size slider's double-tap means "I never chose a size", like every other reset affordance. It used to
    /// write a hardcoded 28, which both marked the score touched and ignored the device default entirely.
    @Test func `clearing staff size goes back to untouched`() {
        let touched = ReaderPreferencesReducer.setStaffSize(base(), 18)
        #expect(touched.staffSize == 18)
        let cleared = ReaderPreferencesReducer.clearStaffSize(touched)
        #expect(cleared.staffSize == nil)
        // Clearing one scalar leaves the others alone.
        #expect(ReaderPreferencesReducer.clearStaffSize(
            ReaderPreferencesReducer.setMasterVolume(touched, 0.4),
        ).masterVolume == 0.4)
    }

    /// Legacy (pre-`schemaVersion`) blobs are demoted against the seed Android actually wrote — a frozen 28.0 — not
    /// against the live default. Once the live default moved to 21/24, comparing against it would strand every
    /// previously-opened score at an explicit 28 AND would reclassify a tablet user's deliberate 24 as untouched.
    @Test func `a legacy blob demotes only the frozen android seed`() {
        /// `legacyReaderPreferencesBlob` is the shared file-scope helper in `ReaderPreferencesBridgeTests.swift` —
        /// same test target, and it already asserts that what it builds really reads as legacy.
        func legacy(_ staffSize: Double) -> String {
            legacyReaderPreferencesBlob(
                ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: staffSize, hiddenStaves: []),
            )
        }
        #expect(ReaderPreferencesReducer.decode(legacy(28))?.staffSize == nil)
        #expect(ReaderPreferencesReducer.decode(legacy(24))?.staffSize == 24)
        #expect(ReaderPreferencesReducer.decode(legacy(21))?.staffSize == 21)
        // A v2 blob is authoritative even at the frozen seed value.
        let current = ReaderPreferencesReducer.encode(
            ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 28, hiddenStaves: []),
        )
        #expect(ReaderPreferencesReducer.decode(current)?.staffSize == 28)
    }
}

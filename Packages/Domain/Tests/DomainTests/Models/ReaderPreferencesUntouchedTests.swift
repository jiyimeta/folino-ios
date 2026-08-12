import Domain
import Testing

/// `nil` == "the user never set this — resolve to the current default". These tests pin the two load-bearing rules:
/// clamping must never materialize a value out of `nil`, and explicit values (including explicit defaults) survive.
struct ReaderPreferencesUntouchedTests {
    private let scoreID = ScoreItemID()

    @Test func `omitted scalar fields default to nil`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(prefs.staffSize == nil)
        #expect(prefs.honorLayoutBreaks == nil)
        #expect(prefs.masterVolume == nil)
        #expect(prefs.transposeSemitones == nil)
    }

    @Test func `nil survives the memberwise init for all four fields`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: nil, hiddenStaves: [],
            honorLayoutBreaks: nil, masterVolume: nil, transposeSemitones: nil,
        )
        #expect(prefs.staffSize == nil)
        #expect(prefs.honorLayoutBreaks == nil)
        #expect(prefs.masterVolume == nil)
        #expect(prefs.transposeSemitones == nil)
    }

    @Test func `set values still clamp`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 99, hiddenStaves: [],
            masterVolume: 5.0, transposeSemitones: 12,
        )
        #expect(prefs.staffSize == 28)
        #expect(prefs.masterVolume == 3.0)
        #expect(prefs.transposeSemitones == 7)
    }

    @Test func `an explicit default value is kept as some`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 14, hiddenStaves: [],
            honorLayoutBreaks: true, masterVolume: 1.0, transposeSemitones: 0,
        )
        #expect(prefs.staffSize == 14)
        #expect(prefs.honorLayoutBreaks == true)
        #expect(prefs.masterVolume == 1.0)
        #expect(prefs.transposeSemitones == 0)
    }

    @Test func `effective accessors resolve nil to the static defaults`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(prefs.effectiveMasterVolume == 1.0)
        #expect(prefs.effectiveTransposeSemitones == 0)
    }

    /// `honorLayoutBreaks` resolves against the caller's default for the same reason `staffSize` does: the default is
    /// device-class-dependent, so it cannot live on the model.
    @Test func `effectiveHonorLayoutBreaks follows the injected default`() {
        let untouched = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(untouched.effectiveHonorLayoutBreaks(default: false) == false)
        #expect(untouched.effectiveHonorLayoutBreaks(default: true) == true)
        let touched = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], honorLayoutBreaks: false)
        #expect(touched.effectiveHonorLayoutBreaks(default: true) == false)
    }

    @Test func `effectiveStaffSize follows the injected default`() {
        let untouched = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(untouched.effectiveStaffSize(default: 16) == 16)
        let touched = ReaderPreferences(scoreItemID: scoreID, staffSize: 20, hiddenStaves: [])
        #expect(touched.effectiveStaffSize(default: 16) == 20)
    }

    @Test func `explicit zero transpose is not a score-bound override`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], transposeSemitones: 0)
        #expect(!prefs.hasScoreBoundOverrides)
    }

    @Test func `clearingScoreBoundOverrides resets transpose to nil`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], transposeSemitones: 3)
        #expect(prefs.clearingScoreBoundOverrides().transposeSemitones == nil)
    }
}

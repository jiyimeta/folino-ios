import EditorCore
import Testing

/// The spelling math `NoteNameFormatter` used to own, now shared with Android — which assembles the same readout
/// from its own string resources and so needs the letter, the alteration and the octave, not a formatted string.
///
/// Every tpc here was derived from the line of fifths and cross-checked against `NoteNameFormatterTests`, which pins
/// C=14, C♯=21, D♭=9, B♭=12. Each ±7 in tpc is one alteration step from the same letter, which is how the
/// double-accidental and enharmonic cases below are reached.
@Suite("Note spelling")
struct NoteSpellingTests {
    @Test func `a natural spells without a glyph`() {
        #expect(NoteSpeller.name(pitch: 60, tpc: 14) == "C4")
    }

    @Test func `a flat spells with its glyph and its own letter's octave`() {
        #expect(NoteSpeller.name(pitch: 63, tpc: 11) == "E♭4")
    }

    /// The enharmonic pair the octave bucketing exists for: B♯3 and C♭4 must spell in the LETTER's octave, not the
    /// pitch's. Bucketing the pitch alone puts B♯3 in octave 4 and C♭4 in octave 3.
    @Test func `enharmonic spellings land in their letter's octave`() {
        #expect(NoteSpeller.name(pitch: 60, tpc: 26) == "B♯3")
        #expect(NoteSpeller.name(pitch: 59, tpc: 7) == "C♭4")
    }

    @Test func `a double sharp carries the double glyph`() {
        #expect(NoteSpeller.name(pitch: 62, tpc: 28) == "C𝄪4")
    }

    /// Beyond double, the glyph repeats rather than giving up — rare, but it keeps the readout total.
    @Test func `a triple sharp repeats the single glyph`() {
        #expect(NoteSpeller.name(pitch: 63, tpc: 35) == "C♯♯♯4")
    }

    /// Structured parts, not just the assembled string: this is what Android reads to build the same readout from
    /// its own string resources.
    @Test func `spelling reports letter, alteration and octave separately`() {
        let spelling = NoteSpeller.spelling(pitch: 63, tpc: 11)
        #expect(spelling.letterIndex == 2) // E
        #expect(spelling.alteration == -1)
        #expect(spelling.octave == 4)
    }
}

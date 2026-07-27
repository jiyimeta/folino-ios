import Domain // re-exports SheetMusicCore
@testable import Editor
import SheetMusicCore
import Testing

/// `NoteNameFormatter` spells a note name from a MIDI pitch + tpc and assembles the palette readout string. Name
/// cases are locale-independent (letters + glyphs); the readout assertion looks the localized duration name up
/// through the Editor bundle rather than hard-coding Japanese, so the suite passes under any locale.
struct NoteNameFormatterTests {
    @Test
    func `middle C is C 4`() {
        #expect(NoteNameFormatter.name(pitch: 60, tpc: 14) == "C4")
    }

    @Test
    func `c sharp four from sharp tpc`() {
        #expect(NoteNameFormatter.name(pitch: 61, tpc: 21) == "C♯4")
    }

    @Test
    func `d flat four from flat tpc`() {
        #expect(NoteNameFormatter.name(pitch: 61, tpc: 9) == "D♭4")
    }

    @Test
    func `b flat four`() {
        #expect(NoteNameFormatter.name(pitch: 70, tpc: 12) == "B♭4")
    }

    @Test
    func `c five is next octave`() {
        #expect(NoteNameFormatter.name(pitch: 72, tpc: 14) == "C5")
    }

    @Test
    func `readout contains note name and localized duration`() {
        let score = EditorFixtures.chordAtIndex1()
        let item = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let readout = NoteNameFormatter.readout(for: item, in: score)

        #expect(readout.contains("C4"))
        let quarterName = String(localized: "editor.duration.quarter", bundle: .editorModule)
        #expect(readout.contains(quarterName))
    }
}

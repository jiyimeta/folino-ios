import Domain
import Foundation
import SheetMusicCore

/// The pad's pitch operations — semitone/octave keys, staff-step drag, and accidentals — per spec §5.3/§11-5. All
/// four act on a `.note` selection only (no-op otherwise) and, unlike `inputPitch`, never auto-advance the
/// selection: the engine's post-mutation re-derivation keeps the caret on the same note.
extension EditorViewModel {
    /// ▴/▾ keys: ±1 semitone via `Note.shifted(bySemitones:in:)` (MuseScore arrow-key spelling). No auto-advance.
    public func shiftPitch(bySemitones delta: Int) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        guard let shifted = note.shifted(bySemitones: delta, in: keySig) else { return }
        retune(noteID, pitch: shifted.pitch, tpc: shifted.tpc, accidental: shifted.accidental)
    }

    /// Long-press ▴/▾: ±1 octave, same tpc/accidental. No auto-advance.
    public func shiftOctave(by octaves: Int) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let newPitch = note.pitch + 12 * octaves
        guard (0 ... 127).contains(newPitch) else { return }
        retune(noteID, pitch: newPitch, tpc: note.tpc, accidental: note.accidental)
    }

    /// Writes a pitch onto `noteID` AND onto every note it is tied to, as one undo step — `.setNotePitch` owns the
    /// chain walk now (ssm's `retuneCommand`), including "the accidental glyph belongs to the chain's head alone".
    /// An untied note is a chain of one and plans back to the identical bare `SetNotePitch`.
    private func retune(_ noteID: NoteID, pitch: Int, tpc: Int, accidental: Accidental?) {
        let generationBeforeShift = generation
        apply(.setNotePitch(at: noteID, pitch: pitch, tpc: tpc, accidental: accidental))
        auditionSelectedNote(unlessStillAt: generationBeforeShift)
    }

    /// ♭ ♮ ♯ (long-press 𝄫 𝄪) → `SetAccidental`. `nil` clears the glyph.
    public func setAccidental(_ accidental: Accidental?) {
        guard case let .note(noteID)? = selectedItem else { return }
        let generationBeforeSet = generation
        apply(.setAccidental(at: noteID, accidental: accidental))
        auditionSelectedNote(unlessStillAt: generationBeforeSet)
    }
}

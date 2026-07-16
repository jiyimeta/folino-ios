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
        applyCommand(SetNotePitch(
            at: noteID, pitch: shifted.pitch, tpc: shifted.tpc, accidental: shifted.accidental,
        ))
    }

    /// Long-press ▴/▾: ±1 octave, same tpc/accidental. No auto-advance.
    public func shiftOctave(by octaves: Int) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let newPitch = note.pitch + 12 * octaves
        guard (0 ... 127).contains(newPitch) else { return }
        applyCommand(SetNotePitch(at: noteID, pitch: newPitch, tpc: note.tpc, accidental: note.accidental))
    }

    /// Drag-commit from the Reader overlay (staff steps, positive = up). Applies `SetNotePitch` with the in-key
    /// spelling + `displayedAccidental`. No auto-advance (spec §11-5: off after drag).
    public func commitPitchDrag(steps: Int) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        guard let shifted = StaffStepPitch.diatonicShift(from: note, bySteps: steps, keySig: keySig) else { return }
        let accidental = PitchSpelling.displayedAccidental(forTpc: shifted.tpc, in: keySig)
        applyCommand(SetNotePitch(at: noteID, pitch: shifted.pitch, tpc: shifted.tpc, accidental: accidental))
    }

    /// ♭ ♮ ♯ (long-press 𝄫 𝄪) → `SetAccidental`. `nil` clears the glyph.
    public func setAccidental(_ accidental: Accidental?) {
        guard case let .note(noteID)? = selectedItem else { return }
        applyCommand(SetAccidental(at: noteID, accidental: accidental))
    }
}

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
        retune(noteID, in: score, pitch: shifted.pitch, tpc: shifted.tpc, accidental: shifted.accidental)
    }

    /// Long-press ▴/▾: ±1 octave, same tpc/accidental. No auto-advance.
    public func shiftOctave(by octaves: Int) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let newPitch = note.pitch + 12 * octaves
        guard (0 ... 127).contains(newPitch) else { return }
        retune(noteID, in: score, pitch: newPitch, tpc: note.tpc, accidental: note.accidental)
    }

    /// Writes a pitch onto `noteID` AND onto every note it is tied to, as one command.
    ///
    /// A tie chain is one sounding note written across several slots — that is what the curve tells a player, and
    /// what `MidiRenderer` already assumes when it carries the head's pitch through the chain. Moving only the
    /// notehead under the finger therefore produced something unplayable: two different pitches joined by a tie,
    /// sounding as the original pitch held. The chevrons move the whole chain, however long it is and whichever
    /// member is selected.
    private func retune(_ noteID: NoteID, in score: Score, pitch: Int, tpc: Int, accidental: Accidental?) {
        let chain = TiePlanner.tieChain(containing: noteID, in: score)
        guard !chain.isEmpty else { return }
        let commands: [any EditCommand] = chain.map { member in
            SetNotePitch(
                at: member, pitch: pitch, tpc: tpc,
                // The glyph belongs to the head of the chain: MuseScore prints no accidental on the far side of a
                // tie, and `MeasureAccidentals` deliberately skips tied-back notes — so an accidental written here
                // would be nobody's to take away again.
                accidental: score[member]?.tieBack == nil ? accidental : nil,
            )
        }
        let generationBeforeShift = generation
        if let only = commands.first, commands.count == 1 {
            applyCommand(only)
        } else {
            applyCommand(CompositeEditCommand(commands: commands, location: VoiceElementID(noteID)))
        }
        auditionSelectedNote(unlessStillAt: generationBeforeShift)
    }

    /// ♭ ♮ ♯ (long-press 𝄫 𝄪) → `SetAccidental`. `nil` clears the glyph.
    public func setAccidental(_ accidental: Accidental?) {
        guard case let .note(noteID)? = selectedItem else { return }
        let generationBeforeSet = generation
        applyCommand(SetAccidental(at: noteID, accidental: accidental))
        auditionSelectedNote(unlessStillAt: generationBeforeSet)
    }
}

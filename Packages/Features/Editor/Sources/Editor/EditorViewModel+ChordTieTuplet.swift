import Domain
import Foundation
import SheetMusicCore

/// Chord building, ties, and tuplets — spec §5.4. Every operation reads the current `.note` (or, for tuplets, any)
/// selection and no-ops when it doesn't match the shape the operation needs, or when the underlying engine command
/// is refused.
extension EditorViewModel {
    // MARK: - Chord building

    /// ＋音: arms add-to-chord — the next pitch key / drag ADDS to the selected chord instead of replacing.
    /// A second tap disarms.
    public func toggleAddToChord() {
        isAddToChordArmed.toggle()
    }

    /// −音 → `RemoveNoteFromChord` on the selected notehead (last note leaves a rest, engine-canonical).
    public func removeSelectedNoteFromChord() {
        guard case let .note(noteID)? = selectedItem else { return }
        applyCommand(RemoveNoteFromChord(at: noteID))
    }

    /// iPad +3度 / +8度 → `AddNoteToChord` with `IntervalPlanner`'s pitch.
    public func addIntervalNote(_ interval: EditorInterval) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        let target: (pitch: Int, tpc: Int)? = switch interval {
        case .third: IntervalPlanner.diatonicThirdAbove(note, keySig: keySig)
        case .octave: IntervalPlanner.octaveAbove(note)
        }
        guard let target else { return }
        addNoteToChord(at: noteID, pitch: target.pitch, tpc: target.tpc, keySig: keySig)
    }

    /// The chord-armed branch of `inputPitch` (Task 5 wiring, `EditorViewModel+Input.swift`): adds `letter`'s
    /// in-key pitch, nearest the selected note, to the chord — then clears the arm and selects the added note.
    /// Never auto-advances (spec §5.4).
    func addLetterToChord(_ letter: Character, at noteID: NoteID, in score: Score) {
        isAddToChordArmed = false
        guard let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        guard let target = inKeyPitch(forLetter: letter, nearestTo: note.pitch, keySig: keySig) else { return }
        addNoteToChord(at: noteID, pitch: target.pitch, tpc: target.tpc, keySig: keySig)
    }

    /// Shared `AddNoteToChord` apply + select-the-added-note landing, used by both the chord-arm letter path and
    /// the iPad interval shortcuts. A refused add (duplicate pitch) leaves `generation` and selection untouched.
    private func addNoteToChord(at noteID: NoteID, pitch: Int, tpc: Int, keySig: Int) {
        let accidental = PitchSpelling.displayedAccidental(forTpc: tpc, in: keySig)
        let veID = VoiceElementID(noteID)
        let generationBeforeAdd = generation
        applyCommand(AddNoteToChord(at: veID, pitch: pitch, tpc: tpc, accidental: accidental))
        guard generation != generationBeforeAdd, let score, case let .chord(chord)? = score[veID] else { return }
        select(.note(NoteID(
            staff: noteID.staff,
            measureIndex: noteID.measureIndex,
            voiceIndex: noteID.voiceIndex,
            elementIndex: noteID.elementIndex,
            noteIndexInChord: chord.notes.count - 1,
        )))
    }

    // MARK: - Ties

    /// Whether the selected note has a same-pitch successor (drives the tie button's enabled state).
    public var canTie: Bool {
        guard case let .note(noteID)? = selectedItem, let score else { return false }
        return TiePlanner.tieTarget(for: noteID, in: score) != nil
    }

    /// Adds the tie when absent (`SetTie` ... `sourceTieForward: 1, targetTieBack: 1`), removes it when present
    /// (nil / nil) — reads the selected note's `tieForward` to decide. No-op when there's no tie target.
    public func toggleTie() {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let targetID = TiePlanner.tieTarget(for: noteID, in: score)
        else { return }
        if note.tieForward != nil {
            applyCommand(SetTie(from: noteID, to: targetID, sourceTieForward: nil, targetTieBack: nil))
        } else {
            applyCommand(SetTie(from: noteID, to: targetID, sourceTieForward: 1, targetTieBack: 1))
        }
    }

    // MARK: - Tuplets

    /// Whether the current selection sits inside a tuplet.
    public var isSelectionInTuplet: Bool {
        guard let selectedItem, let score, let staff = score[selectedItem.staff],
              staff.measures.indices.contains(selectedItem.measureIndex)
        else { return false }
        let voices = staff.measures[selectedItem.measureIndex].voices
        guard voices.indices.contains(selectedItem.voiceIndex) else { return false }
        let element = selectedItem.elementIndex
        return voices[selectedItem.voiceIndex].tuplets.contains {
            $0.startIndex <= element && element <= $0.endIndex
        }
    }

    /// One-tap triplet = `createTuplet(actualNotes: 3)`; long-press grid passes 5 / 6 / 7.
    /// `normalNotes` follows MuseScore's convention — the largest power of two strictly less than `actualNotes`
    /// (3→2, 5→4, 6→4, 7→4).
    public func createTuplet(actualNotes: Int) {
        guard let selectedItem else { return }
        let veID = VoiceElementID(
            staff: selectedItem.staff,
            measureIndex: selectedItem.measureIndex,
            voiceIndex: selectedItem.voiceIndex,
            elementIndex: selectedItem.elementIndex,
        )
        applyCommand(CreateTuplet(
            at: veID, actualNotes: actualNotes, normalNotes: Self.normalNotes(forActualNotes: actualNotes),
        ))
    }

    /// Collapses the tuplet containing the selection back into a single chord/rest of the same tick span.
    public func removeTuplet() {
        guard let selectedItem else { return }
        let veID = VoiceElementID(
            staff: selectedItem.staff,
            measureIndex: selectedItem.measureIndex,
            voiceIndex: selectedItem.voiceIndex,
            elementIndex: selectedItem.elementIndex,
        )
        applyCommand(RemoveTuplet(at: veID))
    }

    private static func normalNotes(forActualNotes actualNotes: Int) -> Int {
        var normal = 1
        while normal * 2 < actualNotes {
            normal *= 2
        }
        return normal
    }
}

import Domain
import Foundation
import SheetMusicCore

/// The pad's core operations — note input, delete, duration change — per spec §5.3.
extension EditorViewModel {
    /// Letter key C…B. Rest selected → `InputNote` (wrapped with `SetRestDuration` in a `CompositeEditCommand`
    /// when a different duration is armed). Note selected + add-to-chord armed → `AddNoteToChord` (Task 7). Note
    /// selected, not armed → `SetNotePitch` to that letter's in-key pitch nearest the current pitch. Auto-advances
    /// to the next timed element afterwards (spec §11-5: on after keys).
    public func inputPitch(letter: Character) {
        guard let selectedItem, let score else { return }
        switch selectedItem {
        case let .rest(restID):
            inputPitch(letter: letter, onRest: restID, in: score)
        case let .note(noteID):
            guard !isAddToChordArmed else {
                // Task 7: the chord-arm add-note path (AddNoteToChord) lands here.
                return
            }
            inputPitch(letter: letter, onNote: noteID, in: score)
        case .tuplet, .clef:
            return
        }
    }

    /// ⌫. Multi-note chord + `.note` selection → `RemoveNoteFromChord`; single-note chord or whole-element
    /// selection → `DeleteVoiceElement` (same-duration rest, measure length invariant); `.tuplet` selection →
    /// `RemoveTuplet`. Selection stays on the affected slot (now a rest) via re-derivation.
    public func deleteSelection() {
        guard let selectedItem, let score else { return }
        switch selectedItem {
        case let .note(noteID):
            guard case let .chord(chord)? = score[VoiceElementID(noteID)] else { return }
            if chord.notes.count > 1 {
                applyCommand(RemoveNoteFromChord(at: noteID))
            } else {
                applyCommand(DeleteVoiceElement(at: VoiceElementID(noteID)))
            }
        case let .rest(restID):
            applyCommand(DeleteVoiceElement(at: VoiceElementID(restID)))
        case let .tuplet(tupletID):
            applyCommand(RemoveTuplet(at: VoiceElementID(
                staff: tupletID.staff,
                measureIndex: tupletID.measureIndex,
                voiceIndex: tupletID.voiceIndex,
                elementIndex: tupletID.startElementIndex,
            )))
        case .clef:
            return
        }
    }

    /// Duration key. Applies `SetChordDuration` / `SetRestDuration` to the selection AND arms `armedDuration` for
    /// the next input. With no selection, only arms.
    public func setDuration(_ duration: NoteDuration) {
        armedDuration = duration
        guard let selectedItem else { return }
        switch selectedItem {
        case let .note(noteID):
            applyCommand(SetChordDuration(at: VoiceElementID(noteID), duration: duration))
        case let .rest(restID):
            applyCommand(SetRestDuration(at: VoiceElementID(restID), duration: duration))
        case .tuplet, .clef:
            return
        }
    }

    /// Reference pitch for octave choice: the previous chord's first note walking backwards in voice order from
    /// the selection, else nil.
    func referencePitch(before location: VoiceElementID) -> Int? {
        guard let score, let staff = score[location.staff] else { return nil }
        var measureIndex = location.measureIndex
        var searchFromIndex = location.elementIndex - 1
        while measureIndex >= 0, staff.measures.indices.contains(measureIndex) {
            let voices = staff.measures[measureIndex].voices
            guard voices.indices.contains(location.voiceIndex) else { return nil }
            let elements = voices[location.voiceIndex].elements
            var idx = min(searchFromIndex, elements.count - 1)
            while idx >= 0 {
                if case let .chord(chord) = elements[idx], !chord.notes.isEmpty {
                    return chord.notes.first?.pitch
                }
                idx -= 1
            }
            measureIndex -= 1
            searchFromIndex = Int.max
        }
        return nil
    }

    private func inputPitch(letter: Character, onRest restID: RestID, in score: Score) {
        guard let rest = score[restID],
              let planned = NoteInputPlanner.pitch(
                  forLetter: letter,
                  nearestTo: referencePitch(before: VoiceElementID(restID)),
              )
        else { return }
        let veID = VoiceElementID(restID)
        if let armed = armedDuration, rest.duration != armed {
            applyCommand(CompositeEditCommand(
                commands: [
                    SetRestDuration(at: veID, duration: armed),
                    InputNote(at: restID, pitch: planned.pitch, tpc: planned.tpc),
                ],
                location: veID,
            ))
        } else {
            applyCommand(InputNote(at: restID, pitch: planned.pitch, tpc: planned.tpc))
        }
        advanceSelection(after: veID)
    }

    private func inputPitch(letter: Character, onNote noteID: NoteID, in score: Score) {
        guard let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        guard let target = inKeyPitch(forLetter: letter, nearestTo: note.pitch, keySig: keySig) else { return }
        applyCommand(SetNotePitch(at: noteID, pitch: target.pitch, tpc: target.tpc))
        advanceSelection(after: VoiceElementID(noteID))
    }

    /// Moves the selection to the next timed element after `location` in voice order (spec §11-5: on after
    /// pitch-key input). No-op past the end of the staff.
    private func advanceSelection(after location: VoiceElementID) {
        guard let score, let next = ElementNavigator.nextTimedElement(after: location, in: score) else { return }
        select(SelectionRederivation.item(at: next, in: score, preferringNoteIndex: nil))
    }
}

/// Nearest pitch to `reference` spelled as `letter` under `keySig`: `NoteInputPlanner`'s natural-letter octave
/// search, retargeted by the key's alteration so the search lands on the nearest ALTERED pitch instead.
private func inKeyPitch(
    forLetter letter: Character, nearestTo reference: Int, keySig: Int,
) -> (pitch: Int, tpc: Int)? {
    guard let natural = NoteInputKeyMap.pitch(forLetter: letter, octave: 4) else { return nil }
    let keyedTpc = inKeyTpc(naturalTpc: natural.tpc, keySig: keySig)
    let alteration = (keyedTpc - natural.tpc) / 7
    guard let nearestNatural = NoteInputPlanner.pitch(forLetter: letter, nearestTo: reference - alteration)
    else { return nil }
    return (nearestNatural.pitch + alteration, keyedTpc)
}

/// tpc ≡ naturalTpc (mod 7), shifted into the window `13+keySig ... 19+keySig`. Task 6 moves this into
/// `StaffStepPitch`.
private func inKeyTpc(naturalTpc: Int, keySig: Int) -> Int {
    let low = 13 + keySig
    let offset = ((naturalTpc - low) % 7 + 7) % 7
    return low + offset
}

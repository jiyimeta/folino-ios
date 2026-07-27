import Domain
import Foundation
import SheetMusicCore
import SheetMusicLayout // DurationInterpretation: splits a written duration back into base + dots

/// The pad's core operations — note input, delete, duration change — per spec §5.3.
extension EditorViewModel {
    /// Letter key C…B — writes at the CARET. Rest at the caret → `InputNote` (wrapped with `SetRestDuration` in a
    /// `CompositeEditCommand` when a different duration is armed); note at the caret → `SetNotePitch` to that
    /// letter's in-key pitch nearest the current pitch. Add-to-chord armed is the one exception: it stacks onto the
    /// SELECTED chord (`AddNoteToChord`, Task 7), since what it means is "another note in the one I just wrote".
    ///
    /// Afterwards the selection lands on the note that was written and the caret moves on to the next timed element
    /// (spec §11-5: advance on after keys), so ♯ / ♭ / ⌫ keep addressing the note rather than the empty slot ahead.
    public func inputPitch(letter: Character) {
        guard let score else { return }
        if isAddToChordArmed, case let .note(noteID)? = selectedItem {
            addLetterToChord(letter, at: noteID, in: score)
            return
        }
        guard let caretItem else { return }
        switch caretItem {
        case let .rest(restID):
            inputPitch(letter: letter, onRest: restID, in: score)
        case let .note(noteID):
            inputPitch(letter: letter, onNote: noteID, in: score)
        case .tuplet, .clef:
            return
        }
    }

    /// ⌫ — acts on the SELECTION (the note you last wrote or tapped, not the slot the caret is parked on).
    /// Multi-note chord + `.note` selection → `RemoveNoteFromChord`; single-note chord or whole-element selection →
    /// `DeleteVoiceElement` (same-duration rest, measure length invariant), or a full-measure rest when that delete
    /// empties the measure (see `FullMeasureRestCollapse`); `.tuplet` selection → `RemoveTuplet`. Selection stays on
    /// the affected slot (now a rest) via re-derivation.
    public func deleteSelection() {
        guard let selectedItem, let score else { return }
        switch selectedItem {
        case let .note(noteID):
            guard case let .chord(chord)? = score[VoiceElementID(noteID)] else { return }
            if chord.notes.count > 1 {
                applyCommand(RemoveNoteFromChord(at: noteID))
            } else {
                deleteElement(at: VoiceElementID(noteID), in: score)
            }
        case let .rest(restID):
            deleteElement(at: VoiceElementID(restID), in: score)
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

    /// The rest key. Writes a rest at the selection — which for a note means deleting it (a rest of that note's length
    /// takes its place), and for a rest already there means re-timing it to the ARMED length.
    ///
    /// That second case is why the key isn't note-only: with a whole rest selected, tapping it with the half armed is
    /// a real edit — "make this bar's silence a half rest" — and the key's own glyph, which is the armed length's
    /// rest, is already promising exactly that.
    public func writeRest() {
        guard let selectedItem else { return }
        switch selectedItem {
        case .note, .tuplet:
            deleteSelection()
        case let .rest(restID):
            guard let armed = armedInputDuration else { return }
            let location = VoiceElementID(restID)
            applyCommand(SetRestDuration(at: location, duration: restDuration(armed, at: location)))
        case .clef:
            return
        }
    }

    /// The duration to actually write for a rest of `duration` at `location`: `.measure` when that rest would fill
    /// its bar from beat one, otherwise `duration` unchanged.
    ///
    /// A bar of silence is written as a measure rest, not as a whole rest that happens to be the right length — that
    /// is what MuseScore writes, it is what `.measure` means, and it is the only spelling that stays correct if the
    /// meter changes (a whole rest in 3/4 is simply too long). The same rule the delete path applies through
    /// `FullMeasureRestCollapse`, reached from the other direction: there a bar EMPTIES into one, here a bar is
    /// FILLED with one.
    func restDuration(_ duration: NoteDuration, at location: VoiceElementID) -> NoteDuration {
        guard let score, let staff = score[location.staff],
              staff.measures.indices.contains(location.measureIndex)
        else { return duration }
        let measureDurations = score.effectiveMeasureDurations(
            partIndex: location.staff.partIndex,
            staffIndex: location.staff.staffIndexInPart,
        )
        guard measureDurations.indices.contains(location.measureIndex) else { return duration }
        let measureDuration = measureDurations[location.measureIndex]
        let division = score.division
        guard duration.resolved(in: measureDuration).ticks(division: division)
            == measureDuration.ticks(division: division)
        else { return duration }
        // Only from beat one: a bar-length rest starting anywhere else can't fill the bar, whatever its length says.
        let voices = staff.measures[location.measureIndex].voices
        guard voices.indices.contains(location.voiceIndex) else { return duration }
        let preceding = voices[location.voiceIndex].elements.prefix(location.elementIndex)
        guard !preceding.contains(where: { if case .chord = $0 { true } else { false } }) else { return duration }
        return .measure
    }

    /// Whether the rest key has something to write into: any timed slot, note or rest.
    public var canWriteRest: Bool {
        switch selectedItem {
        case .note, .rest: true
        case .tuplet, .clef, .none: false
        }
    }

    /// `DeleteVoiceElement`, or the whole voice-measure replaced by one full-measure rest when this delete leaves
    /// nothing but rests behind. One command either way, so ⌫ is always a single undo step.
    private func deleteElement(at location: VoiceElementID, in score: Score) {
        guard let plan = FullMeasureRestCollapse.plan(deleting: location, in: score) else {
            applyCommand(DeleteVoiceElement(at: location))
            return
        }
        let generationBeforeDelete = generation
        applyCommand(plan.command)
        guard generation != generationBeforeDelete else { return }
        select(.rest(RestID(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elementIndex: plan.restElementIndex,
        )))
    }

    /// Duration key — arms only, and never touches the score. A length key states what the NEXT note or rest will
    /// be; it is not a way to re-time what is already written. (It used to apply `SetChordDuration` /
    /// `SetRestDuration` to whatever was current, which meant reaching for the next note's length silently rewrote
    /// the previous one.) The armed length reaches the score through `inputPitch`, which sizes the slot it writes
    /// into.
    public func setDuration(_ duration: NoteDuration) {
        armedDuration = duration
    }

    /// Dot key. A tap adds a single augmentation dot, or clears whatever dots are armed; the long-press menu sets
    /// 1 / 2 / 3 outright. Dots ride ON the armed length rather than replacing it — dotted-quarter is the quarter
    /// key and the dot key both lit.
    public func toggleArmedDot() {
        armedDots = armedDots > 0 ? 0 : 1
    }

    public func setArmedDots(_ dots: Int) {
        armedDots = max(0, min(dots, 3))
    }

    // MARK: - The selection's own length (the callout's copy of these keys)

    /// The SELECTED element's length, split into the base value a length key can light and its dot count. This is
    /// what the callout shows — unlike the pad, which shows what the next note will be, the callout is anchored to
    /// one note and describes THAT note.
    public var selectedDuration: (base: NoteDuration, dots: Int)? {
        guard let score, let slot = Self.slot(of: selectedItem), case let .chord(chord)? = score[slot] else {
            return nil
        }
        let split = DurationInterpretation.split(chord.duration)
        return (split.base, split.dots)
    }

    /// Re-times the selected element to `base`, keeping whatever dots it already has. Refused by the engine (and so a
    /// no-op) inside a tuplet, where the member lengths are the tuplet's to decide.
    public func setSelectionDuration(_ base: NoteDuration) {
        applyToSelection(base: base, dots: selectedDuration?.dots ?? 0)
    }

    /// Sets the selected element's augmentation dots, keeping its base length.
    public func setSelectionDots(_ dots: Int) {
        guard let current = selectedDuration else { return }
        applyToSelection(base: current.base, dots: max(0, min(dots, 3)))
    }

    /// One dot on, or all dots off — the callout's tap-to-toggle, mirroring `toggleArmedDot`.
    public func toggleSelectionDot() {
        guard let current = selectedDuration else { return }
        applyToSelection(base: current.base, dots: current.dots > 0 ? 0 : 1)
    }

    private func applyToSelection(base: NoteDuration, dots: Int) {
        guard let selectedItem, let slot = Self.slot(of: selectedItem) else { return }
        let duration = dots > 0 ? base.dotted(dots) : base
        switch selectedItem {
        case .note:
            applyCommand(SetChordDuration(at: slot, duration: duration))
        case .rest:
            applyCommand(SetRestDuration(at: slot, duration: restDuration(duration, at: slot)))
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
        let generationBeforeInput = generation
        if let armed = armedInputDuration, rest.duration != armed, !isInsideTuplet(veID) {
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
        land(after: veID, unlessStillAt: generationBeforeInput)
    }

    /// A letter key on a slot that already holds a note: re-pitch it, and re-time it to the armed length too.
    ///
    /// Both, not just the pitch. Writing over an existing note is still writing a note, and the length keys say what
    /// the next note will be — so a quarter armed over an existing half has to produce a quarter. Leaving the length
    /// alone silently ignored half of what the pad was showing.
    private func inputPitch(letter: Character, onNote noteID: NoteID, in score: Score) {
        guard let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        guard let target = inKeyPitch(forLetter: letter, nearestTo: note.pitch, keySig: keySig) else { return }
        let veID = VoiceElementID(noteID)
        let pitch = SetNotePitch(at: noteID, pitch: target.pitch, tpc: target.tpc)
        let generationBeforeInput = generation
        if let armed = armedInputDuration, case let .chord(chord)? = score[veID],
           chord.duration != armed, !isInsideTuplet(veID)
        {
            applyCommand(CompositeEditCommand(
                commands: [SetChordDuration(at: veID, duration: armed), pitch],
                location: veID,
            ))
        } else {
            applyCommand(pitch)
        }
        land(after: veID, unlessStillAt: generationBeforeInput)
    }

    /// Where input leaves the two markers: the selection on the note just written at `location`, the caret on the
    /// next timed element in voice order (spec §11-5: advance on after pitch-key input) — nil past the end of the
    /// staff. Both are placed in one go, before the audition, so the preview sounds the note that was actually
    /// written. A refused edit (`generation` unmoved) leaves everything where it was.
    private func land(after location: VoiceElementID, unlessStillAt previousGeneration: Int) {
        guard generation != previousGeneration, let score else { return }
        let written = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)
        let next = ElementNavigator.nextTimedElement(after: location, in: score)
            .flatMap { SelectionRederivation.item(at: $0, in: score, preferringNoteIndex: nil) }
        place(selection: written, caret: next)
        auditionSelectedNote(unlessStillAt: previousGeneration)
    }
}

/// Nearest pitch to `reference` spelled as `letter` under `keySig`: `NoteInputPlanner`'s natural-letter octave
/// search, retargeted by the key's alteration so the search lands on the nearest ALTERED pitch instead.
/// Not `private`: Task 7's `EditorViewModel+ChordTieTuplet.swift` reuses it for the chord-arm letter-add path.
func inKeyPitch(
    forLetter letter: Character, nearestTo reference: Int, keySig: Int,
) -> (pitch: Int, tpc: Int)? {
    guard let natural = NoteInputKeyMap.pitch(forLetter: letter, octave: 4) else { return nil }
    let keyedTpc = StaffStepPitch.inKeyTpc(naturalTpc: natural.tpc, keySig: keySig)
    let alteration = (keyedTpc - natural.tpc) / 7
    guard let nearestNatural = NoteInputPlanner.pitch(forLetter: letter, nearestTo: reference - alteration)
    else { return nil }
    return (nearestNatural.pitch + alteration, keyedTpc)
}

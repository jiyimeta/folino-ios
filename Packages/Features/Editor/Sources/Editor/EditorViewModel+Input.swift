import Domain
import Foundation
import SheetMusicCore
import SheetMusicLayout // DurationInterpretation: splits a written duration back into base + dots

/// The pad's core operations — note input, delete, duration change — per spec §5.3.
extension EditorViewModel {
    /// Letter key C…B — writes at the CARET. Rest at the caret → `InputNote` (wrapped with `SetRestDuration` in a
    /// `CompositeEditCommand` when a different duration is armed); note at the caret → `SetNotePitch`. Either way the
    /// pitch is the letter's spelling AS THE BAR READS IT (`MeasureAccidentals.plannedPitch`) nearest the previous
    /// note: the key signature's, unless an accidental earlier in the same measure has already respelled that staff
    /// line. Add-to-chord armed is the one exception: it stacks onto the SELECTED chord (`AddNoteToChord`, Task 7),
    /// since what it means is "another note in the one I just wrote".
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

    /// The rest key. Writes a rest of the ARMED length at the selection — over a note, the note goes and that rest
    /// takes its place; over a rest already there, that rest is re-timed.
    ///
    /// One rule for both, because the key's own glyph is the armed length's rest and it promises the same thing
    /// whatever is underneath: "this slot becomes a rest of THIS length". A note is not the exception it used to be —
    /// deleting it and keeping the note's own length silently ignored half of what the pad was showing, exactly as
    /// `inputPitch(letter:onNote:)` refuses to do on the pitch side.
    public func writeRest() {
        guard let selectedItem, let score else { return }
        switch selectedItem {
        case let .note(noteID):
            writeRest(over: VoiceElementID(noteID), in: score)
        case let .rest(restID):
            writeRest(over: VoiceElementID(restID), in: score)
        case .tuplet:
            deleteSelection()
        case .clef:
            return
        }
    }

    /// Writes a rest of the armed length over the timed slot at `location`, whatever is currently in it.
    ///
    /// Over a note that means `DeleteVoiceElement` (which leaves a rest of the NOTE's length) paired with the
    /// re-time, as one composite so it is a single undo step; over a rest the re-time alone. Falls back to the plain
    /// delete when there is no re-timing to do — nothing armed, or the armed length is what's already there — so
    /// that path keeps `FullMeasureRestCollapse`'s "an emptied bar reads as one measure rest". Re-timing has to skip
    /// the collapse: it would throw away the length the user just stated. A length that fills the bar still lands as
    /// `.measure`, via `restDuration(_:at:)`. Inside a tuplet the engine refuses the re-time and its refusal would
    /// take the delete down with it (`CompositeEditCommand` is all-or-nothing), so those slots delete plainly too.
    private func writeRest(over location: VoiceElementID, in score: Score) {
        guard case let .chord(current)? = score[location] else { return }
        let isNote = !current.notes.isEmpty
        guard let armed = armedInputDuration, current.duration != armed, !isInsideTuplet(location) else {
            if isNote { deleteSelection() }
            return
        }
        // Outlasting the bar is spelled as a chain across the barline, exactly as a note is — minus the ties, which
        // rests don't take. Without it the engine refuses the lengthening and the key goes dead near a barline.
        if let plan = CrossBarInputPlanner.plan(.rest, duration: armed, at: location, in: score) {
            applyCommand(CompositeEditCommand(commands: plan.commands, location: plan.head))
            return
        }
        let retime = SetRestDuration(at: location, duration: restDuration(armed, at: location))
        if isNote {
            applyCommand(CompositeEditCommand(
                commands: [DeleteVoiceElement(at: location), retime], location: location,
            ))
        } else {
            applyCommand(retime)
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

    /// Re-times the selected element to `base`, keeping whatever dots it already has — spilling across the barline
    /// as a tied chain (a run of rests, for a rest) when the bar can't hold the new length. Refused by the engine
    /// (and so a no-op) inside a tuplet, where the member lengths are the tuplet's to decide.
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
        guard let selectedItem, let slot = Self.slot(of: selectedItem), let score else { return }
        let duration = dots > 0 ? base.dotted(dots) : base
        switch selectedItem {
        case .note:
            guard case let .chord(chord)? = score[slot] else { return }
            if retimeCrossingBarline(.chord(chord), duration: duration, at: slot, in: score) { return }
            applyCommand(SetChordDuration(at: slot, duration: duration))
        case .rest:
            if retimeCrossingBarline(.rest, duration: duration, at: slot, in: score) { return }
            applyCommand(SetRestDuration(at: slot, duration: restDuration(duration, at: slot)))
        case .tuplet, .clef:
            return
        }
    }

    /// A length the bar can't hold → re-spell the item as a chain across the barline, and report that the re-time is
    /// done. False means this isn't that case and the caller's ordinary single-slot command should run.
    ///
    /// The callout's length keys are the pad's keys pointed at one item instead of at the next one, so they have to
    /// reach as far: without this, asking a beat-4 quarter for a half was simply refused by the engine and the key
    /// read as dead — the very thing `CrossBarInputPlanner` was written to fix on the input side. One composite, so
    /// it stays one undo step, and the selection re-derives onto the chain's head.
    private func retimeCrossingBarline(
        _ content: CrossBarInputPlanner.Content, duration: NoteDuration, at slot: VoiceElementID, in score: Score,
    ) -> Bool {
        guard let plan = CrossBarInputPlanner.plan(content, duration: duration, at: slot, in: score) else {
            return false
        }
        applyCommand(CompositeEditCommand(commands: plan.commands, location: plan.head))
        return true
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
        let veID = VoiceElementID(restID)
        guard let rest = score[restID],
              let planned = MeasureAccidentals.plannedPitch(
                  forLetter: letter,
                  nearestTo: referencePitch(before: veID),
                  at: veID,
                  in: score,
              )
        else { return }
        let generationBeforeInput = generation
        if writeCrossingBarline(
            pitch: planned.pitch, tpc: planned.tpc, at: veID, in: score, from: generationBeforeInput,
        ) { return }
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
        let veID = VoiceElementID(noteID)
        guard let note = score[noteID],
              let target = MeasureAccidentals.plannedPitch(
                  forLetter: letter, nearestTo: note.pitch, at: veID, in: score,
              )
        else { return }
        let pitch = SetNotePitch(at: noteID, pitch: target.pitch, tpc: target.tpc)
        let generationBeforeInput = generation
        if writeCrossingBarline(
            pitch: target.pitch, tpc: target.tpc, at: veID, in: score, from: generationBeforeInput,
        ) { return }
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

    /// The armed length doesn't fit the bar → write it as tied notes across the barline instead (spelled by
    /// `CrossBarInputPlanner`), and report that input is done. False means this isn't that case and the caller's
    /// ordinary single-slot path should run.
    ///
    /// The chain is one composite, so it is one undo step; the selection lands on the note's first piece while the
    /// caret advances past its last, which is the same "selection on what you wrote, caret on what's next" split
    /// every other input takes — just measured across the whole chain rather than one slot.
    private func writeCrossingBarline(
        pitch: Int, tpc: Int, at location: VoiceElementID, in score: Score, from previousGeneration: Int,
    ) -> Bool {
        guard let armed = armedInputDuration,
              let plan = CrossBarInputPlanner.plan(
                  .chord(Chord(duration: armed, notes: [Note(pitch: pitch, tpc: tpc)])),
                  duration: armed, at: location, in: score,
              )
        else { return false }
        applyCommand(CompositeEditCommand(commands: plan.commands, location: plan.head))
        land(selection: plan.head, caretAfter: plan.tail, unlessStillAt: previousGeneration)
        return true
    }

    /// Where input leaves the two markers: the selection on the note just written at `location`, the caret on the
    /// next timed element in voice order (spec §11-5: advance on after pitch-key input) — nil past the end of the
    /// staff. Both are placed in one go, before the audition, so the preview sounds the note that was actually
    /// written. A refused edit (`generation` unmoved) leaves everything where it was.
    private func land(after location: VoiceElementID, unlessStillAt previousGeneration: Int) {
        land(selection: location, caretAfter: location, unlessStillAt: previousGeneration)
    }

    /// The two-slot form of `land(after:)`, for a note written as a tied chain: the selection belongs on where the
    /// note starts, the caret on what follows where it ends.
    private func land(
        selection slot: VoiceElementID, caretAfter tail: VoiceElementID, unlessStillAt previousGeneration: Int,
    ) {
        guard generation != previousGeneration, let score else { return }
        let written = SelectionRederivation.item(at: slot, in: score, preferringNoteIndex: nil)
        let next = ElementNavigator.nextTimedElement(after: tail, in: score)
            .flatMap { SelectionRederivation.item(at: $0, in: score, preferringNoteIndex: nil) }
        place(selection: written, caret: next)
        auditionSelectedNote(unlessStillAt: previousGeneration)
    }
}

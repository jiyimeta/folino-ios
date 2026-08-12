import Domain
import EditorCore
import Foundation
import SheetMusicCore
import SheetMusicLayout // DurationInterpretation: splits a written duration back into base + dots

/// The pad's core operations — note input, delete, duration change — per spec §5.3.
extension EditorViewModel {
    /// Letter key C…B — writes at the CARET. Rest at the caret → `.inputNote`; note at the caret → `.writeNote`.
    /// Both carry the armed length, and both re-time the slot to it in the same undo step. Either way the pitch is
    /// the letter's spelling AS THE BAR READS IT (`MeasureAccidentals.plannedPitch`) nearest the previous note: the
    /// key signature's, unless an accidental earlier in the same measure has already respelled that staff line.
    /// Add-to-chord armed is the one exception: it stacks onto the SELECTED chord (`.addNoteToChord`), since what it
    /// means is "another note in the one I just wrote".
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
                apply(.removeNoteFromChord(at: noteID))
            } else {
                deleteElement(at: VoiceElementID(noteID))
            }
        case let .rest(restID):
            deleteElement(at: VoiceElementID(restID))
        case let .tuplet(tupletID):
            apply(.removeTuplet(at: VoiceElementID(
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
    /// `.writeRest` is the whole operation — over a note it deletes and re-times as one undo step, over a rest it
    /// re-times, and it spells a chain across the barline or promotes a bar-filling length to `.measure` on its own.
    ///
    /// Falls back to `deleteSelection()` when there is no re-timing to ask for — nothing armed, or the armed length
    /// is what is already there. That path goes through `.delete`, which collapses an emptied bar into one measure
    /// rest; `.writeRest` deliberately does not, because a stated length is not an emptied bar. Inside a tuplet the
    /// member lengths are the tuplet's to decide and the engine refuses the re-time, so those slots delete plainly
    /// too.
    private func writeRest(over location: VoiceElementID, in score: Score) {
        guard case let .chord(current)? = score[location] else { return }
        guard let armed = armedInputDuration, current.duration != armed, !isInsideTuplet(location) else {
            if !current.notes.isEmpty { deleteSelection() }
            return
        }
        apply(.writeRest(at: location, duration: armed))
    }

    /// Whether the rest key has something to write into: any timed slot, note or rest.
    public var canWriteRest: Bool {
        switch selectedItem {
        case .note, .rest: true
        case .tuplet, .clef, .none: false
        }
    }

    /// The delete, or the whole voice-measure replaced by one full-measure rest when it leaves nothing but rests
    /// behind. One undo step either way — `.delete` decides which, from the same `FullMeasureRestCollapse` this
    /// used to call.
    ///
    /// No explicit `select(...)` afterwards: `ScoreEditSession`'s `.delete` case threads the collapse's own
    /// `restElementIndex` through as the affected location precisely so re-derivation lands the selection on the new
    /// measure rest. (`ReplaceVoiceElements` reports element 0 on its own, which is usually the clef or time
    /// signature rather than the rest — that is what the threading is for.)
    private func deleteElement(at location: VoiceElementID) {
        apply(.delete(at: location))
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

    /// The callout's length keys are the pad's keys pointed at one item instead of at the next one, so they have to
    /// reach as far — including past a barline, which the session's own cross-bar planning is what makes work.
    private func applyToSelection(base: NoteDuration, dots: Int) {
        guard let selectedItem, let slot = Self.slot(of: selectedItem) else { return }
        let duration = dots > 0 ? base.dotted(dots) : base
        switch selectedItem {
        case .note: apply(.setChordDuration(at: slot, duration: duration))
        case .rest: apply(.setRestDuration(at: slot, duration: duration))
        case .tuplet, .clef: return
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
        let veID = VoiceElementID(restID)
        guard let planned = MeasureAccidentals.plannedPitch(
            forLetter: letter,
            nearestTo: referencePitch(before: veID),
            at: veID,
            in: score,
        )
        else { return }
        let generationBeforeInput = generation
        apply(.inputNote(at: restID, pitch: planned.pitch, tpc: planned.tpc, duration: armedInputDuration))
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
        let generationBeforeInput = generation
        apply(.writeNote(at: veID, pitch: target.pitch, tpc: target.tpc, duration: armedInputDuration))
        land(after: veID, unlessStillAt: generationBeforeInput)
    }

    /// Where input leaves the two markers: the selection on the note just written, the caret on the next timed
    /// element in voice order (spec §11-5: advance on after pitch-key input) — nil past the end of the staff. Both
    /// are placed in one go, before the audition, so the preview sounds the note that was actually written. A
    /// refused edit (`generation` unmoved) leaves everything where it was.
    ///
    /// The caret advance walks from the END of a tie chain, not from `location`. A note whose armed length outran
    /// the bar is written as a tied chain occupying several slots — it lands AT `location` but does not end there,
    /// and the caret has to clear the whole chain rather than park inside it. The session reports the chain's head
    /// as the affected location and does not report its tail, so the tail is walked for here.
    private func land(after location: VoiceElementID, unlessStillAt previousGeneration: Int) {
        guard generation != previousGeneration, let score else { return }
        let written = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)
        let next = ElementNavigator.nextTimedElement(after: tailOfTie(from: location, in: score), in: score)
            .flatMap { SelectionRederivation.item(at: $0, in: score, preferringNoteIndex: nil) }
        place(selection: written, caret: next)
        auditionSelectedNote(unlessStillAt: previousGeneration)
    }

    /// The last slot of a tied chain starting at `location`, or `location` itself when nothing is tied forward.
    private func tailOfTie(from location: VoiceElementID, in score: Score) -> VoiceElementID {
        var tail = location
        while case let .chord(chord)? = score[tail], chord.notes.first?.tieForward != nil,
              let next = ElementNavigator.nextTimedElement(after: tail, in: score)
        {
            tail = next
        }
        return tail
    }
}

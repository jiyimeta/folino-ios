import Domain
import Foundation
import SheetMusicCore
import SheetMusicLayout // DurationInterpretation: splits a written duration back into base + dots

/// The pad's core operations — note input, delete, duration change — per spec §5.3.
extension EditorViewModel {
    /// Letter key C…B — writes at the CARET. Rest at the caret → `.inputNote` (composited with a re-time when a
    /// different duration is armed); note at the caret → a two-way fork: notehead 0 (or a length that crosses the
    /// barline) takes `.writeNote`, which re-pitches AND re-times in one step, while a caret on an upper notehead
    /// of an existing chord (added via ＋音, then typed over) takes a narrower `.setNotePitch` — composited with
    /// `.setChordDuration` when a length is armed too, since `.setNotePitch` alone never re-times. Either way the
    /// pitch is the letter's spelling AS THE BAR READS IT (`MeasureAccidentals.plannedConcertPitch`) nearest the
    /// previous note: the key signature's, unless an accidental earlier in the same measure has already respelled
    /// that staff line — and on a transposing staff, the bar that reads it is the WRITTEN one, so C on a B♭
    /// clarinet in concert C major means the C♯ its D-major signature spells, stored as a concert B♮. Add-to-chord
    /// armed is the one exception: it stacks onto the SELECTED chord (`.addNoteToChord`, Task 7), since what it
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
    /// Multi-note chord + `.note` selection → `.removeNoteFromChord`; single-note chord or whole-element selection →
    /// `.delete` (same-duration rest, measure length invariant), or a full-measure rest when that delete empties the
    /// measure (the engine's own full-measure-rest collapse); `.tuplet` selection → `.removeTuplet`. Selection stays
    /// on the affected slot (now a rest) via re-derivation.
    public func deleteSelection() {
        guard let selectedItem, let score else { return }
        switch selectedItem {
        case let .note(noteID):
            guard case let .chord(chord)? = score[VoiceElementID(noteID)] else { return }
            if chord.notes.count > 1 {
                apply(.removeNoteFromChord(at: noteID))
            } else {
                deleteElement(at: VoiceElementID(noteID), in: score)
            }
        case let .rest(restID):
            deleteElement(at: VoiceElementID(restID), in: score)
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
    /// The guard is the key's INTERPRETATION and stays here: with nothing armed, the armed length already in the
    /// slot, or a tuplet member (whose lengths are the tuplet's to decide), the key falls back to a plain delete on
    /// a note and does nothing on a rest — exactly as before. Everything past the guard is planning, and
    /// `.writeRest` owns it now: the cross-barline run of rests, the `.measure` promotion for a bar-filling length,
    /// and the delete-plus-retime composite over a note (with the PLAIN delete — re-timing must not collapse the
    /// bar it empties, that would throw away the length the user just stated).
    private func writeRest(over location: VoiceElementID, in score: Score) {
        guard case let .chord(current)? = score[location] else { return }
        let isNote = !current.notes.isEmpty
        guard let armed = armedInputDuration, current.duration != armed, !isInsideTuplet(location) else {
            if isNote {
                deleteSelection()
            }
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

    /// `.delete`: a plain delete leaves a same-duration rest; a delete that empties its bar collapses the voice-
    /// measure to ONE measure rest (the engine's own full-measure-rest collapse), reporting the collapsed rest as
    /// the affected location — so re-derivation lands the selection there without the explicit `select` this method
    /// used to do.
    private func deleteElement(at location: VoiceElementID, in _: Score) {
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

    private func applyToSelection(base: NoteDuration, dots: Int) {
        guard let selectedItem, let slot = Self.slot(of: selectedItem) else { return }
        let duration = dots > 0 ? base.dotted(dots) : base
        switch selectedItem {
        case .note:
            // `.setChordDuration` spells a length the bar can't hold as a chain across the barline itself — from
            // the chord ALREADY in the slot, so its other notes survive — and the engine's refusal of a bad slot
            // is the same observable no-op the old early-return produced.
            apply(.setChordDuration(at: slot, duration: duration))
        case .rest:
            apply(.setRestDuration(at: slot, duration: duration))
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
        let veID = VoiceElementID(restID)
        guard let rest = score[restID],
              let planned = MeasureAccidentals.plannedConcertPitch(
                  forWrittenLetter: letter,
                  nearestTo: referencePitch(before: veID),
                  at: veID,
                  in: score,
              )
        else { return }
        // The armed length rides as the intent's `duration` — ssm re-times the slot, skips the re-time inside a
        // tuplet, and spells a length that outruns the bar as a tied chain. `nil` when there is nothing to re-time,
        // mirroring the old guard exactly: ssm's `.inputNote` does not skip a same-length re-time on its own, and a
        // no-op `SetRestDuration` must not ride along in the undo step.
        var duration: NoteDuration?
        if let armed = armedInputDuration, rest.duration != armed {
            duration = armed
        }
        // Decided BEFORE the apply, against the pre-edit score: after a chain write the caret belongs past the
        // chain's tail, but after an in-bar write it belongs one slot on even if the slot's note is (or becomes)
        // tied to something else — walking the chain unconditionally would overshoot there.
        //
        // The predicate measures the armed length against the bar without asking whether the slot is inside a
        // tuplet, where ssm skips the re-time and so writes no chain at all. Harmless HERE, and only here: the
        // target is a rest, a rest cannot already be tied, so the write's own chain is the only one there is and
        // `chainTail` falls back to `head` when it did not produce one. The note-input site below has no such
        // guarantee — see the comment there.
        let crossesBar = duration.map { !CrossBarInputPlanner.fitsInMeasure($0, at: veID, in: score) } ?? false
        let generationBeforeInput = generation
        guard apply(.inputNote(at: restID, pitch: planned.pitch, tpc: planned.tpc, duration: duration)) else {
            return
        }
        if crossesBar, let mutated = self.score {
            land(
                selection: veID,
                caretAfter: chainTail(from: veID, in: mutated),
                unlessStillAt: generationBeforeInput,
            )
        } else {
            land(after: veID, unlessStillAt: generationBeforeInput)
        }
    }

    // PARITY(android): letter input on a chord's upper notehead — Android's `.writeNote` path re-pitches
    //   notehead 0; Android still needs the caret-notehead `.setNotePitch` branch iOS keeps here.
    /// A letter key on a slot that already holds a note: re-pitch it, and re-time it to the armed length too —
    /// `.writeNote`'s own meaning. Writing over an existing note is still writing a note, and the length keys say
    /// what the next note will be, so a quarter armed over an existing half has to produce a quarter.
    ///
    /// One case stays host-side: a caret naming a chord's UPPER notehead (`noteIndexInChord != 0`) — reached by
    /// ＋音 adding a note (which selects the added note) and typing a letter to fix it. `.writeNote` re-pitches
    /// notehead 0; the user in that flow means the notehead the caret names, so the intent is built to say so
    /// (which notehead a letter means is interpretation, not planning). The barline case takes `.writeNote` for
    /// any index: the pre-intent code already collapsed the chord to a single note of the new pitch when the armed
    /// length crossed the bar, and that is exactly what `.writeNote` plans.
    private func inputPitch(letter: Character, onNote noteID: NoteID, in score: Score) {
        let veID = VoiceElementID(noteID)
        guard let note = score[noteID],
              let target = MeasureAccidentals.plannedConcertPitch(
                  forWrittenLetter: letter, nearestTo: note.pitch, at: veID, in: score,
              )
        else { return }
        var duration: NoteDuration?
        if let armed = armedInputDuration, case let .chord(chord)? = score[veID], chord.duration != armed {
            duration = armed
        }
        // Same predicate as the rest-input site, and NOT harmless for the same reason: the target here already
        // holds a note, which may already be tied forward. When the predicate says "crosses the bar" but ssm wrote
        // no chain — inside a tuplet, where it skips the re-time, or in a slot with no bar left to overrun —
        // `chainTail` walks the PRE-EXISTING chain instead of the one this write made, and the caret lands past a
        // chain the write never created. Left alone deliberately: reaching it needs a tuplet member or staff-end
        // slot, an armed length that overruns the bar, and a pre-existing tie forward, all at once, and the cost is
        // a misplaced caret rather than a wrong note.
        let crossesBar = duration.map { !CrossBarInputPlanner.fitsInMeasure($0, at: veID, in: score) } ?? false
        let generationBeforeInput = generation
        let applied: Bool
        if noteID.noteIndexInChord == 0 || crossesBar {
            applied = apply(.writeNote(at: veID, pitch: target.pitch, tpc: target.tpc, duration: duration))
        } else {
            let repitch = EditIntent.setNotePitch(
                at: noteID, pitch: target.pitch, tpc: target.tpc, accidental: nil,
            )
            if let duration, !isInsideTuplet(veID) {
                applied = apply(.composite([.setChordDuration(at: veID, duration: duration), repitch]))
            } else {
                applied = apply(repitch)
            }
        }
        guard applied else { return }
        if crossesBar, let mutated = self.score {
            land(
                selection: veID,
                caretAfter: chainTail(from: veID, in: mutated),
                unlessStillAt: generationBeforeInput,
            )
        } else {
            land(after: veID, unlessStillAt: generationBeforeInput)
        }
    }

    /// Where input leaves the two markers: the selection on the note just written at `location`, the caret on the
    /// next timed element in voice order (spec §11-5: advance on after pitch-key input) — nil past the end of the
    /// staff. Both are placed in one go, before the audition, so the preview sounds the note that was actually
    /// written. A refused edit (`generation` unmoved) leaves everything where it was.
    private func land(after location: VoiceElementID, unlessStillAt previousGeneration: Int) {
        land(selection: location, caretAfter: location, unlessStillAt: previousGeneration)
    }

    /// The last slot of the tie chain a cross-barline write just produced at `head` — where the caret's "past what
    /// was written" starts. The chain a fresh write produces is exactly the planner's chain (its head has no
    /// `tieBack`), and `TiePlanner.tieChain` walks it whole; a chain of one hands back `head` itself.
    private func chainTail(from head: VoiceElementID, in score: Score) -> VoiceElementID {
        let headNote = NoteID(
            staff: head.staff,
            measureIndex: head.measureIndex,
            voiceIndex: head.voiceIndex,
            elementIndex: head.elementIndex,
            noteIndexInChord: 0,
        )
        guard let tail = TiePlanner.tieChain(containing: headNote, in: score).last else { return head }
        return VoiceElementID(tail)
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

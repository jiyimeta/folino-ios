import Domain
import Foundation
import SheetMusicCore

/// Chord building, ties, and tuplets — spec §5.4. Every operation reads the current `.note` (or, for tuplets, any)
/// selection and no-ops when it doesn't match the shape the operation needs, or when the underlying engine command
/// is refused.
extension EditorSessionCore {
    // MARK: - Chord building

    /// ＋音: arms add-to-chord — the next pitch key / drag ADDS to the selected chord instead of replacing.
    /// A second tap disarms.
    public func toggleAddToChord() {
        isAddToChordArmed.toggle()
    }

    /// −音 → `.removeNoteFromChord` on the selected notehead (last note leaves a rest, engine-canonical).
    public func removeSelectedNoteFromChord() {
        guard case let .note(noteID)? = selectedItem else { return }
        apply(.removeNoteFromChord(at: noteID))
    }

    /// Stacks a diatonic third or an octave onto the selected note, via `.addNoteToChord` with `IntervalPlanner`'s
    /// pitch. **No UI drives this today** — it backed the regular-width palette card's `+3度` / `+8度` keys, and the
    /// card was removed because it sat on the score permanently for keys the pad already carries. Kept because
    /// re-offering the shortcut is then a view-only change; covered by `EditorViewModelChordTests`.
    public func addIntervalNote(_ interval: DiatonicInterval) {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return }
        let keySig = score.activeKey(at: noteID)
        let target: (pitch: Int, tpc: Int)? = switch interval {
        case .third: IntervalPlanner.diatonicThirdAbove(note, keySig: keySig)
        case .octave: IntervalPlanner.octaveAbove(note)
        }
        guard let target else { return }
        addNoteToChord(at: noteID, pitch: target.pitch, tpc: target.tpc, keySig: keySig)
    }

    /// The chord-armed branch of `inputPitch` (wired in `EditorViewModel+Input.swift`): adds `letter`'s
    /// in-key pitch, nearest the selected note, to the chord — then clears the arm and selects the added note.
    /// Never auto-advances (spec §5.4).
    ///
    /// It plans through the same `plannedConcertPitch` the two `inputPitch` sites do: the letter is a letter on
    /// the page either way, so on a transposing staff it has to be resolved in the written space and stored as
    /// the concert pitch that engraves back to it.
    func addLetterToChord(_ letter: Character, at noteID: NoteID, in score: Score) {
        isAddToChordArmed = false
        guard let note = score[noteID],
              let target = MeasureAccidentals.plannedConcertPitch(
                  forWrittenLetter: letter, nearestTo: note.pitch, at: VoiceElementID(noteID), in: score,
              )
        else { return }
        addNoteToChord(
            at: noteID, pitch: target.pitch, tpc: target.tpc, keySig: score.activeKey(at: noteID),
        )
    }

    /// Shared `.addNoteToChord` apply + select-the-added-note landing, used by both the chord-arm letter path and
    /// the iPad interval shortcuts. A refused add (duplicate pitch) leaves `revision` and selection untouched.
    /// Auditions the newly added note on success (spec §5.6).
    private func addNoteToChord(at noteID: NoteID, pitch: Int, tpc: Int, keySig: Int) {
        let accidental = PitchSpelling.displayedAccidental(forTpc: tpc, in: keySig)
        let veID = VoiceElementID(noteID)
        guard apply(.addNoteToChord(at: veID, pitch: pitch, tpc: tpc, accidental: accidental)) != nil,
              let score, case let .chord(chord)? = score[veID] else { return }
        let addedNoteID = NoteID(
            staff: noteID.staff,
            measureIndex: noteID.measureIndex,
            voiceIndex: noteID.voiceIndex,
            elementIndex: noteID.elementIndex,
            noteIndexInChord: chord.notes.count - 1,
        )
        select(.note(addedNoteID))
        audition(addedNoteID)
    }

    // MARK: - Ties

    /// Whether the selected note has a same-pitch successor (drives the tie button's enabled state — and, in the
    /// callout, whether the key appears at all: a tie key with nothing to tie to is just a puzzle).
    public var canTie: Bool {
        guard case let .note(noteID)? = selectedItem, let score else { return false }
        return TiePlanner.tieTarget(for: noteID, in: score) != nil
    }

    /// Whether the selected note is ALREADY tied forward — what lights the callout's tie key, so one key reads as
    /// both "tie this" and "these are tied, tap to undo".
    public var isSelectionTied: Bool {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID] else { return false }
        return note.tieForward != nil
    }

    /// The pad's tie ＋ key: writes a note of the ARMED length in the slot after the selected one, at the same
    /// pitch, and ties the two together — one intent, one undo step.
    ///
    /// ssm's `.composite` reports its FIRST member's location (the appended note), where the old command pinned the
    /// location to the source note so re-derivation kept the selection there. Compensate with an explicit
    /// `select(.note(sourceID))` after a successful apply — the same post-apply explicit landing
    /// `addNoteToChord(at:pitch:tpc:keySig:)` already does. The source's own slot index is untouched by the append
    /// (`.setRestDuration`'s planning re-splices what FOLLOWS the slot; a cross-bar plan rewrites from the next slot
    /// on), so the captured id stays valid.
    public func appendTiedNote() {
        guard case let .note(sourceID)? = selectedItem else { return }
        guard let intent = tieAppendIntent() else { return }
        guard apply(intent) != nil else { return }
        select(.note(sourceID))
    }

    /// Whether `appendTiedNote` has somewhere to write: a selected note, an armed length, and a rest in the next
    /// slot to overwrite. A note already sitting there would have to be pushed aside, which is not what a tie key
    /// should quietly do.
    public var canAppendTiedNote: Bool {
        tieAppendIntent() != nil
    }

    /// The composite `appendTiedNote` applies: write the pitch into the next slot at the armed length (ssm spells a
    /// length that outruns the bar as a tied chain), then tie the source note onto what was written. Sound because
    /// ssm plans composite members against the PRE-edit score and `.setTie` is built purely from scalars — and the
    /// chain's head lands at the very slot being written (`CrossBarInputPlanner.Plan.head`), so the tie target's
    /// `NoteID` is `next`'s slot whether the length fits the bar or spills across it.
    ///
    /// `nil` (the key dims) when the length has no plan AND no room: the chain would run off the end of the staff,
    /// and issuing the write anyway just hands the engine an edit it refuses — a lit key that does nothing.
    private func tieAppendIntent() -> EditIntent? {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let armed = armedInputDuration,
              let next = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score),
              case let .chord(target)? = score[next], target.notes.isEmpty
        else { return nil }
        guard CrossBarInputPlanner.fitsInMeasure(armed, at: next, in: score)
            || CrossBarInputPlanner.plan(
                .chord(Chord(duration: armed, notes: [Note(pitch: note.pitch, tpc: note.tpc)])),
                duration: armed, at: next, in: score,
            ) != nil
        else { return nil }
        let restID = RestID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
        )
        let headID = NoteID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
            noteIndexInChord: 0,
        )
        return .composite([
            .inputNote(
                at: restID, pitch: note.pitch, tpc: note.tpc,
                duration: target.duration != armed ? armed : nil,
            ),
            .setTie(from: noteID, to: headID, sourceTieForward: 1, targetTieBack: 1),
        ])
    }

    /// Adds the tie when absent (`.setTie` ... `sourceTieForward: 1, targetTieBack: 1`), removes it when present
    /// (nil / nil) — reads the selected note's `tieForward` to decide. No-op when there's no tie target.
    public func toggleTie() {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let targetID = TiePlanner.tieTarget(for: noteID, in: score)
        else { return }
        if note.tieForward != nil {
            apply(.setTie(from: noteID, to: targetID, sourceTieForward: nil, targetTieBack: nil))
        } else {
            apply(.setTie(from: noteID, to: targetID, sourceTieForward: 1, targetTieBack: 1))
        }
    }

    // MARK: - Tuplets

    /// Whether the CARET sits inside a tuplet — the tuplet key rides with the duration keys, and like them it acts on
    /// the slot the next note goes into rather than on the note last written.
    public var isCaretInTuplet: Bool {
        guard let caretItem else { return false }
        return isInsideTuplet(Self.tupletTarget(caretItem))
    }

    /// Whether `location` is one of a tuplet's members.
    ///
    /// Input asks this before it re-times a slot: the member lengths inside a tuplet are the tuplet's to decide, and
    /// the engine refuses `.setRestDuration` / `.setChordDuration` there outright. Since input applies the armed
    /// length and the note in ONE composite, that refusal used to take the note down with it — which is why nothing
    /// could be written into a triplet after its first member.
    func isInsideTuplet(_ location: VoiceElementID) -> Bool {
        guard let score, let staff = score[location.staff],
              staff.measures.indices.contains(location.measureIndex)
        else { return false }
        let voices = staff.measures[location.measureIndex].voices
        guard voices.indices.contains(location.voiceIndex) else { return false }
        let element = location.elementIndex
        return voices[location.voiceIndex].tuplets.contains {
            $0.startIndex <= element && element <= $0.endIndex
        }
    }

    /// Writes a tuplet of `actualNotes` at the caret and remembers the size: the key's long-press menu passes 2 … 6,
    /// and whatever came through last is what a plain tap writes from then on (`armedTuplet`).
    /// `normalNotes` follows MuseScore's convention — the largest power of two strictly less than `actualNotes`
    /// (2→1, 3→2, 5→4, 6→4).
    public func createTuplet(actualNotes: Int) {
        // Defensive lower bound: `CreateTuplet` asserts `actualNotes >= 2` (a 1:1 tuplet is meaningless), and its
        // precondition is a hard crash. The UI only ever passes 2 … 6, but returning here closes that crash-risk
        // for any out-of-range programmatic caller.
        guard actualNotes >= 2 else { return }
        // Recorded before the caret check, and whether or not the engine accepts the edit: picking a size from the
        // menu is a statement about what you are writing, and it would be strange for the key to keep saying 3
        // because the one slot you tried it on refused.
        armedTuplet = actualNotes
        guard let caretItem else { return }
        apply(.createTuplet(
            at: Self.tupletTarget(caretItem),
            actualNotes: actualNotes,
            normalNotes: Self.normalNotes(forActualNotes: actualNotes),
        ))
    }

    /// Collapses the tuplet containing the caret back into a single chord/rest of the same tick span.
    public func removeTuplet() {
        guard let caretItem else { return }
        apply(.removeTuplet(at: Self.tupletTarget(caretItem)))
    }

    private static func tupletTarget(_ item: SheetMusicCore.ScoreItemID) -> VoiceElementID {
        VoiceElementID(
            staff: item.staff,
            measureIndex: item.measureIndex,
            voiceIndex: item.voiceIndex,
            elementIndex: item.elementIndex,
        )
    }

    private static func normalNotes(forActualNotes actualNotes: Int) -> Int {
        var normal = 1
        while normal * 2 < actualNotes {
            normal *= 2
        }
        return normal
    }
}

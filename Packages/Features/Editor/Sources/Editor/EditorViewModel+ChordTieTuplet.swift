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
    /// Auditions the newly added note on success (spec §5.6).
    private func addNoteToChord(at noteID: NoteID, pitch: Int, tpc: Int, keySig: Int) {
        let accidental = PitchSpelling.displayedAccidental(forTpc: tpc, in: keySig)
        let veID = VoiceElementID(noteID)
        let generationBeforeAdd = generation
        applyCommand(AddNoteToChord(at: veID, pitch: pitch, tpc: tpc, accidental: accidental))
        guard generation != generationBeforeAdd, let score, case let .chord(chord)? = score[veID] else { return }
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

    /// The pad's tie ＋ key: writes a note of the ARMED length in the slot after the selected one, at the same pitch,
    /// and ties the two together — one command, one undo step.
    ///
    /// This is the "hold this note longer" gesture, and a tie is how a score says that across a barline or past what
    /// a single note value can express. As a bare toggle the key was near-useless: it needed you to have already
    /// written the same pitch twice in a row, which nobody does by hand — you write the note, then decide to hold it.
    /// (Toggling an existing tie off still lives in the callout's tie key, which appears exactly when there is one.)
    public func appendTiedNote() {
        guard let plan = tieAppendPlan() else { return }
        applyCommand(CompositeEditCommand(commands: plan.commands, location: plan.location))
    }

    /// Whether `appendTiedNote` has somewhere to write: a selected note, an armed length, and a rest in the next slot
    /// to overwrite. A note already sitting there would have to be pushed aside, which is not what a tie key should
    /// quietly do.
    public var canAppendTiedNote: Bool {
        tieAppendPlan() != nil
    }

    private func tieAppendPlan() -> (commands: [any EditCommand], location: VoiceElementID)? {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let armed = armedInputDuration,
              let next = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score),
              case let .chord(target)? = score[next], target.notes.isEmpty
        else { return nil }
        // A tie is the one gesture whose whole point is holding a note past what one slot can express, so the armed
        // length outrunning the bar is the expected case here rather than an edge one: spell it as a chain across
        // the barline and tie the selected note onto its head.
        if let plan = CrossBarNoteInputPlanner.plan(
            pitch: note.pitch, tpc: note.tpc, duration: armed, at: next, in: score,
        ) {
            let tieOntoChain = SetTie(
                from: noteID,
                to: NoteID(
                    staff: plan.head.staff,
                    measureIndex: plan.head.measureIndex,
                    voiceIndex: plan.head.voiceIndex,
                    elementIndex: plan.head.elementIndex,
                    noteIndexInChord: 0,
                ),
                sourceTieForward: 1,
                targetTieBack: 1,
            )
            return (plan.commands + [tieOntoChain], VoiceElementID(noteID))
        }
        // No plan and no room means the chain would run off the end of the staff: there is nowhere to put the
        // length being asked for, and issuing the single-slot write anyway just hands the engine an edit it
        // refuses — a lit key that does nothing. Report it as unavailable so the key dims instead.
        guard CrossBarNoteInputPlanner.fitsInMeasure(armed, at: next, in: score) else { return nil }
        let restID = RestID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
        )
        var commands: [any EditCommand] = []
        // Re-time the slot first when it isn't already the armed length — the same composite shape note input uses,
        // and the reason this works at all: `SetRestDuration` re-splices what FOLLOWS the slot, leaving the slot's
        // own index (and so the `InputNote` / `SetTie` addresses below) valid.
        if target.duration != armed {
            commands.append(SetRestDuration(at: next, duration: armed))
        }
        commands.append(InputNote(at: restID, pitch: note.pitch, tpc: note.tpc))
        commands.append(SetTie(
            from: noteID,
            to: NoteID(
                staff: next.staff,
                measureIndex: next.measureIndex,
                voiceIndex: next.voiceIndex,
                elementIndex: next.elementIndex,
                noteIndexInChord: 0,
            ),
            sourceTieForward: 1,
            targetTieBack: 1,
        ))
        return (commands, VoiceElementID(noteID))
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

    /// Whether the CARET sits inside a tuplet — the tuplet key rides with the duration keys, and like them it acts on
    /// the slot the next note goes into rather than on the note last written.
    public var isCaretInTuplet: Bool {
        guard let caretItem else { return false }
        return isInsideTuplet(Self.tupletTarget(caretItem))
    }

    /// Whether `location` is one of a tuplet's members.
    ///
    /// Input asks this before it re-times a slot: the member lengths inside a tuplet are the tuplet's to decide, and
    /// the engine refuses `SetRestDuration` / `SetChordDuration` there outright. Since input applies the armed length
    /// and the note in ONE composite, that refusal used to take the note down with it — which is why nothing could be
    /// written into a triplet after its first member.
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
        applyCommand(CreateTuplet(
            at: Self.tupletTarget(caretItem),
            actualNotes: actualNotes,
            normalNotes: Self.normalNotes(forActualNotes: actualNotes),
        ))
    }

    /// Collapses the tuplet containing the caret back into a single chord/rest of the same tick span.
    public func removeTuplet() {
        guard let caretItem else { return }
        applyCommand(RemoveTuplet(at: Self.tupletTarget(caretItem)))
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

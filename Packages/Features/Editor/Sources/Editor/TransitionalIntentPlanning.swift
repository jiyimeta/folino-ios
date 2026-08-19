import Domain
import Foundation
import SheetMusicCore

/// TRANSITIONAL — Task 4 of `docs/superpowers/plans/2026-08-19-cross-session-undo.md` deletes this file.
///
/// A verbatim host-side copy of `ScoreEditSession`'s intent planning (swift-sheet-music 1.15.0,
/// `ScoreEditSession.command(for:in:depth:)` and its private helpers), kept only so the Editor's call sites can
/// migrate to `EditIntent` one reviewable slice at a time while the view model still holds a `ScoreEditor` —
/// `ScoreEditSession` exposes no raw-command apply, so the two entry points cannot share one engine any other way.
/// Task 4 swaps the engine to `ScoreEditSession` (whose own copy of this planning takes over) and deletes this file.
/// Do not fix or improve anything here: fidelity to the ssm original is the point, and the gate suites prove it.
enum TransitionalIntentPlanning {
    /// Mirrors `ScoreEditSession.maxCompositeIntentDepth`.
    private static let maxCompositeIntentDepth = 8

    /// Mirrors `ScoreEditSession.command(for:in:depth:)`: plans an intent against `score`. `nil` when the intent has
    /// nothing to do; throws when a nested `.composite` exceeds the depth bound or names an impossible edit.
    static func command(for intent: EditIntent, in score: Score, depth: Int = 0) throws -> (any EditCommand)? {
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            return inputNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
        case let .setRestDuration(location, duration):
            // Cross-bar first, then the bar-filling `.measure` promotion — see ssm's comments.
            if let plan = CrossBarInputPlanner.plan(.rest, duration: duration, at: location, in: score) {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetRestDuration(
                at: location, duration: RestDurationPromotion.promoted(duration, at: location, in: score),
            )
        case let .setChordDuration(location, duration):
            // Planned from the chord ALREADY in the slot so its other notes survive the barline. No `.measure`
            // promotion: that spelling is rest-only.
            if case let .chord(current)? = score[location], !current.notes.isEmpty,
               let plan = CrossBarInputPlanner.plan(.chord(current), duration: duration, at: location, in: score)
            {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetChordDuration(at: location, duration: duration)
        case let .delete(location):
            // A delete that empties its bar leaves ONE measure rest; the collapsed rest's element index is threaded
            // into the composite's location so `lastAffectedLocation` names the rest, not element 0.
            if let plan = FullMeasureRestCollapse.plan(deleting: location, in: score) {
                return CompositeEditCommand(
                    commands: [plan.command],
                    location: VoiceElementID(
                        staff: location.staff,
                        measureIndex: location.measureIndex,
                        voiceIndex: location.voiceIndex,
                        elementIndex: plan.restElementIndex,
                    ),
                )
            }
            return DeleteVoiceElement(at: location)
        case let .composite(intents):
            guard depth < maxCompositeIntentDepth else {
                throw SheetMusicError.invalidEdit(
                    reason: "composite nesting exceeds depth limit (\(maxCompositeIntentDepth))",
                )
            }
            let commands = try intents.compactMap { try command(for: $0, in: score, depth: depth + 1) }
            guard let first = commands.first else { return nil }
            guard commands.count > 1 else { return first }
            return CompositeEditCommand(commands: commands, location: first.affectedLocation)
        case let .writeNote(location, pitch, tpc, duration):
            return try writeNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
        case let .writeRest(location, duration):
            return writeRestCommand(at: location, duration: duration, in: score)
        case let .setNotePitch(location, pitch, tpc, accidental):
            return retuneCommand(at: location, pitch: pitch, tpc: tpc, accidental: accidental, in: score)
        case .setAccidental, .addNoteToChord, .removeNoteFromChord, .setTie, .createTuplet, .removeTuplet:
            return try directNoteEditCommand(for: intent)
        }
    }

    /// Mirrors `ScoreEditSession.inputNoteCommand`: write a note into a rest slot, re-timing it in the same undo
    /// step — bare inside a tuplet, a tied chain when the length outruns the bar.
    private static func inputNoteCommand(
        at location: RestID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) -> any EditCommand {
        let write = InputNote(at: location, pitch: pitch, tpc: tpc)
        guard let duration else { return write }
        let slot = VoiceElementID(location)
        guard !isInTuplet(slot, in: score) else { return write }
        if let plan = CrossBarInputPlanner.plan(
            .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
            duration: duration, at: slot, in: score,
        ) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        return CompositeEditCommand(
            commands: [SetRestDuration(at: slot, duration: duration), write],
            location: slot,
        )
    }

    /// Mirrors `ScoreEditSession.writeRestCommand`: make the slot a rest of `duration`, whatever is in it now.
    /// The delete inside is the PLAIN one — `.delete` keeps the full-measure collapse, this intent must not.
    private static func writeRestCommand(
        at location: VoiceElementID, duration: NoteDuration, in score: Score,
    ) -> (any EditCommand)? {
        guard case let .chord(current)? = score[location] else { return nil }
        if let plan = CrossBarInputPlanner.plan(.rest, duration: duration, at: location, in: score) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        let retime = SetRestDuration(
            at: location, duration: RestDurationPromotion.promoted(duration, at: location, in: score),
        )
        guard !current.notes.isEmpty else { return retime }
        return CompositeEditCommand(
            commands: [DeleteVoiceElement(at: location), retime], location: location,
        )
    }

    /// Mirrors `ScoreEditSession.retuneCommand`: the pitch goes onto `location` AND every note it is tied to, as
    /// one command; the accidental glyph onto the chain's head alone. A chain of one comes back as a bare
    /// `SetNotePitch`.
    private static func retuneCommand(
        at location: NoteID, pitch: Int, tpc: Int, accidental: Accidental?, in score: Score,
    ) -> (any EditCommand)? {
        let chain = TiePlanner.tieChain(containing: location, in: score)
        guard !chain.isEmpty else { return nil }
        let commands: [any EditCommand] = chain.map { member in
            SetNotePitch(
                at: member, pitch: pitch, tpc: tpc,
                accidental: score[member]?.tieBack == nil ? accidental : nil,
            )
        }
        guard commands.count > 1 else { return commands[0] }
        return CompositeEditCommand(commands: commands, location: VoiceElementID(location))
    }

    /// Mirrors `ScoreEditSession.directNoteEditCommand`: the six intents that map straight onto an `EditCommand`.
    private static func directNoteEditCommand(for intent: EditIntent) throws -> (any EditCommand)? {
        if case let .setAccidental(location, accidental) = intent {
            return SetAccidental(at: location, accidental: accidental)
        }
        if case let .addNoteToChord(location, pitch, tpc, accidental) = intent {
            return AddNoteToChord(at: location, pitch: pitch, tpc: tpc, accidental: accidental)
        }
        if case let .removeNoteFromChord(location) = intent {
            return RemoveNoteFromChord(at: location)
        }
        if case let .setTie(source, target, sourceTieForward, targetTieBack) = intent {
            return SetTie(
                from: source, to: target,
                sourceTieForward: sourceTieForward, targetTieBack: targetTieBack,
            )
        }
        if case let .createTuplet(location, actualNotes, normalNotes) = intent {
            guard actualNotes > 1, normalNotes > 0 else {
                throw SheetMusicError.invalidEdit(
                    reason: "createTuplet: ratio \(actualNotes):\(normalNotes) is not a tuplet",
                )
            }
            return CreateTuplet(at: location, actualNotes: actualNotes, normalNotes: normalNotes)
        }
        if case let .removeTuplet(location) = intent {
            return RemoveTuplet(at: location)
        }
        return nil
    }

    /// Mirrors `ScoreEditSession.writeNoteCommand`: re-pitch the chord already in `location` (notehead 0), re-timing
    /// it in the same undo step; a barline-crossing length is spelled as a fresh single-note chain at the NEW pitch.
    /// Throws when the slot holds a rest — that is `.inputNote`'s case.
    private static func writeNoteCommand(
        at location: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) throws -> any EditCommand {
        guard case let .chord(current)? = score[location], !current.notes.isEmpty else {
            throw SheetMusicError.invalidEdit(reason: "writeNote: no chord at \(location)")
        }
        let repitch = SetNotePitch(
            at: NoteID(
                staff: location.staff,
                measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex,
                noteIndexInChord: 0,
            ),
            pitch: pitch, tpc: tpc,
        )
        guard let duration, current.duration != duration, !isInTuplet(location, in: score) else {
            return repitch
        }
        if let plan = CrossBarInputPlanner.plan(
            .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
            duration: duration, at: location, in: score,
        ) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        return CompositeEditCommand(
            commands: [SetChordDuration(at: location, duration: duration), repitch],
            location: location,
        )
    }

    /// Mirrors `ScoreEditSession.isInTuplet`.
    private static func isInTuplet(_ slot: VoiceElementID, in score: Score) -> Bool {
        guard let staff = score[slot.staff],
              staff.measures.indices.contains(slot.measureIndex)
        else { return false }
        let voices = staff.measures[slot.measureIndex].voices
        guard voices.indices.contains(slot.voiceIndex) else { return false }
        return voices[slot.voiceIndex].tuplets.contains {
            slot.elementIndex >= $0.startIndex && slot.elementIndex <= $0.endIndex
        }
    }
}

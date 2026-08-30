import Domain
import Foundation
import SheetMusicCore

/// Where the two markers land, and which note that decision asks to be heard.
///
/// Split out of `EditorSessionCore.swift` to keep that file inside SwiftLint's length budget, along the same seam
/// main drew when it pulled `EditorViewModel+Selection.swift` out of its own view model — and the two halves belong
/// together for a reason beyond size: `selectFromTap` is exactly the place where placing a marker and deciding to
/// sound a note are one action.
extension EditorSessionCore {
    // MARK: - Selection re-derivation

    /// Re-derives the selection and the caret from the engine's post-mutation `lastAffectedLocation`. Engine IDs are
    /// positional, so a stored selection can drift after any mutation — after every apply/undo/redo both are
    /// recomputed against the current score. When no slot was touched (`lastAffectedLocation == nil`) they are
    /// preserved rather than cleared.
    ///
    /// Which of the two followed the intent depends on which one it was aimed at. The keys are split between them
    /// (duration / tuplet write at the caret, ⌫ / ♯ / ♭ / tie edit the selection), so re-deriving both from the
    /// affected slot would collapse the lead the caret holds during a run of input: a duration key would drag the
    /// selection off the note just written, and ♯ would drag the caret back onto it, making the next letter overwrite
    /// what was just sharpened. Whichever one wasn't aimed at keeps its own slot; when the two already share a slot —
    /// the ordinary case, and every case before the first note of a run — both follow.
    func rederiveSelection() {
        guard let session, let location = session.lastAffectedLocation else { return }
        let score = session.score
        let affected = SelectionRederivation.item(
            at: location, in: score, preferringNoteIndex: previousNoteIndex(at: location),
        )
        let selectionSlot = Self.slot(of: selectedItem)
        let caretSlot = Self.slot(of: caretItem)
        if caretSlot == location, selectionSlot != location {
            place(selection: rederived(selectionSlot, in: score) ?? affected, caret: affected)
        } else if selectionSlot == location, caretSlot != location {
            place(selection: affected, caret: rederived(caretSlot, in: score) ?? affected)
        } else {
            select(affected)
        }
    }

    /// Re-resolves a slot the intent did NOT target against the mutated score. `nil` when the slot was spliced away
    /// (the caller then falls back to the affected location, so neither marker is left dangling).
    private func rederived(_ slot: VoiceElementID?, in score: Score) -> SheetMusicCore.ScoreItemID? {
        guard let slot else { return nil }
        return SelectionRederivation.item(at: slot, in: score, preferringNoteIndex: nil)
    }

    /// The voice slot an item occupies. Tuplet brackets (and clefs, which never reach the selection) don't name a
    /// single slot, so they resolve to `nil`.
    public static func slot(of item: SheetMusicCore.ScoreItemID?) -> VoiceElementID? {
        switch item {
        case let .note(id): VoiceElementID(id)
        case let .rest(id): VoiceElementID(id)
        case .tuplet, .clef, .none: nil
        }
    }

    /// The `noteIndexInChord` of the current selection when it is a `.note` anchored at exactly `location`, so
    /// re-derivation can keep the caret on the same chord tone across edits that add or remove siblings.
    private func previousNoteIndex(at location: VoiceElementID) -> Int? {
        guard case let .note(noteID)? = selectedItem,
              noteID.staff == location.staff,
              noteID.measureIndex == location.measureIndex,
              noteID.voiceIndex == location.voiceIndex,
              noteID.elementIndex == location.elementIndex
        else { return nil }
        return noteID.noteIndexInChord
    }

    /// Picks `item` explicitly — caret and selection land together. Every path that names a target directly (tap,
    /// ← / →, post-intent re-derivation) goes through here; only note input deliberately splits the two, via
    /// `place(selection:caret:)`.
    public func select(_ item: SheetMusicCore.ScoreItemID?) {
        place(selection: item, caret: item)
    }

    /// Sets selection and caret independently. Note input passes different values — it leaves the selection on the
    /// note it just wrote and moves the caret to the next slot — and so does an append that must NOT move either:
    /// `appendMeasure` restores both to what they named before the insert, since a bar added at the end shifts no
    /// existing slot and re-deriving would jump both markers onto the new last bar.
    public func place(selection item: SheetMusicCore.ScoreItemID?, caret: SheetMusicCore.ScoreItemID?) {
        selectedItem = item
        caretItem = caret
        // Every ordinary placement names a slot, and a slot begins at a column — so the two stay in step here, and
        // only the column stepper (which can land BETWEEN onsets) writes `caretColumn` on its own.
        caretColumn = Self.slot(of: caret).flatMap { slot in
            score.flatMap { ColumnNavigation.column(of: slot, in: $0) }
        }
        armFromSelectionIfNeeded()
        selectionRevision += 1
    }

    /// Places the two markers at `column`, drawing the caret on whatever slot covers it.
    ///
    /// Used by ← / →, which may land between onsets — an empty bar stepped through by the armed duration — where
    /// the covering slot's own start is NOT the column. Everything else goes through `place(selection:caret:)`,
    /// whose column follows its slot.
    func place(column: ScoreColumn, preferring voiceIndex: Int) {
        guard let score, let covering = coveringSlot(at: column, preferring: voiceIndex, in: score) else { return }
        let item = SelectionRederivation.item(at: covering, in: score, preferringNoteIndex: nil)
        selectedItem = item
        caretItem = item
        caretColumn = column
        armFromSelectionIfNeeded()
        selectionRevision += 1
    }

    /// The slot to draw the caret on at `column`.
    ///
    /// A voice that STARTS something at the column wins — its own if it does, otherwise the lowest-numbered voice
    /// that does. A slot the column merely runs THROUGH is the last resort, and only because a column between every
    /// voice's onsets has to be drawn somewhere (→ stepping the armed duration across an empty bar is the case that
    /// puts it there).
    ///
    /// The order matters, and getting it wrong is visible rather than subtle: with a quarter in the feet voice under
    /// two eighths in the hands, stepping to the second eighth would draw the caret on the quarter it is halfway
    /// through — the marker would appear not to move at all, and the next → would look like it had skipped a beat.
    ///
    /// On a single-voice staff — most scores — there is only one voice to ask, which is why none of this changes
    /// anything for them.
    func coveringSlot(at column: ScoreColumn, preferring voiceIndex: Int, in score: Score) -> VoiceElementID? {
        guard score.parts.indices.contains(column.staff.partIndex),
              score.parts[column.staff.partIndex].staves.indices.contains(column.staff.staffIndexInPart)
        else { return nil }
        let measures = score.parts[column.staff.partIndex].staves[column.staff.staffIndexInPart].measures
        guard measures.indices.contains(column.measureIndex) else { return nil }
        let voices = measures[column.measureIndex].voices.indices

        let preferred = ColumnNavigation.slot(inVoice: voiceIndex, at: column, in: score)
        if let preferred, preferred.tickWithinSlot == 0 {
            return preferred.slot
        }
        for candidate in voices where candidate != voiceIndex {
            if let resolved = ColumnNavigation.slot(inVoice: candidate, at: column, in: score),
               resolved.tickWithinSlot == 0
            {
                return resolved.slot
            }
        }
        if let preferred {
            return preferred.slot
        }
        for candidate in voices {
            if let resolved = ColumnNavigation.slot(inVoice: candidate, at: column, in: score) {
                return resolved.slot
            }
        }
        return nil
    }

    /// Arms the length keys from whatever was just picked, but ONLY while nothing is armed yet — which in practice
    /// means the first note or rest touched in a session. A pad that opens with no length lit has no answer to "what
    /// will the next note be", and making the first pick supply it beats making the user state it twice; after that
    /// the armed length is the user's own choice and selecting other notes must not quietly overwrite it.
    private func armFromSelectionIfNeeded() {
        guard armedDuration == nil, let score, let slot = Self.slot(of: selectedItem),
              case let .chord(chord)? = score[slot]
        else { return }
        // `.fraction` durations carry their dots (and any tuplet scaling) baked in; split them back into the base
        // value a key can light plus the dot count the dot key can light.
        let split = DurationInterpretation.split(chord.duration)
        armedDuration = split.base
        armedDots = split.dots
    }

    // MARK: - Auditioning (the decision, not the sound)

    /// Marks `noteID` as the note to preview. `EditorViewModel` sounds it; on Android the bridge does.
    public func audition(_ noteID: NoteID) {
        guard session != nil else { return }
        pendingAudition = noteID
    }

    /// Call-site helper for the pitch-changing ops: previews the current `.note` selection, but only when the last
    /// `apply` actually mutated the score (`revision` advanced past `previousRevision`). A refused edit — an
    /// out-of-range shift, say — leaves nothing to sound.
    func auditionSelectedNote(unlessStillAt previousRevision: Int) {
        guard revision != previousRevision, case let .note(noteID)? = selectedItem else { return }
        audition(noteID)
    }

    /// Selects an item that was picked OUTSIDE this session — the reader's last tap-to-seek — so entering edit mode
    /// picks up where the finger left off instead of opening onto an inert pad.
    ///
    /// Two rules, and both are behavior rather than presentation, which is why they are here rather than in each
    /// host: an ID the current score no longer contains is dropped (engine IDs are positional, and the score can
    /// have moved on between that tap and this session), and **nothing is auditioned**. `selectFromTap` sounds
    /// because a tap asked to hear that note; opening a session did not ask for anything.
    public func selectCarriedItem(_ item: SheetMusicCore.ScoreItemID?) {
        guard let item, let score, let slot = Self.slot(of: item), score[slot] != nil else {
            select(nil)
            return
        }
        select(item)
    }

    /// Selects what a tap on the score resolved to, and previews it when it is a note.
    ///
    /// Hearing the note you just aimed at is half of how you know you hit the right one — and it would be odd for
    /// the same tap to speak on one screen and go silent on the other, which is why tapping outside edit mode
    /// auditions too (`ReaderPlaybackSession.setManualCursor`). Never over a running transport, for the same reason
    /// the seek path doesn't: a one-shot preview on top of continuous playback.
    ///
    /// This lives here rather than in each host because "which taps sound" is behavior, and behavior is shared:
    /// iOS reaches it from `EditorViewModel.handleTap`, Android from `EditorBridge.selectItem`. It used to be iOS
    /// host code only, which is exactly how Android's edit mode ended up silent on tap.
    public func selectFromTap(_ item: SheetMusicCore.ScoreItemID?) {
        select(item)
        guard case let .note(noteID)? = item, !isPlaybackActive else { return }
        audition(noteID)
    }
}

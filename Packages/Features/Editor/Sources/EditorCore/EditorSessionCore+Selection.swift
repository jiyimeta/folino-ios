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
        armFromSelectionIfNeeded()
        selectionRevision += 1
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

import Domain
import Foundation
import SheetMusicCore
import SheetMusicUI

// Where the selection and the caret land after the score changes underneath them. Split out of `EditorViewModel.swift`
// to keep that file inside SwiftLint's length budget; this is one subject with one entry point (`rederiveSelection`),
// which every mutation — apply, undo, redo, discard — calls exactly once.

extension EditorViewModel {
    /// Re-derives the selection and the caret from the engine's post-mutation `lastAffectedLocation`. Engine IDs are
    /// positional, so a stored selection can drift after any mutation — after every apply/undo/redo both are
    /// recomputed against the current score. When no slot was touched (`lastAffectedLocation == nil`) they are
    /// preserved rather than cleared.
    ///
    /// Which of the two followed the command depends on which one it was aimed at. The keys are split between them
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

    /// Re-resolves a slot that the command did NOT target against the mutated score. `nil` when the slot was spliced
    /// away (the caller then falls back to the affected location, so neither marker is left dangling).
    private func rederived(_ slot: VoiceElementID?, in score: Score) -> SheetMusicCore.ScoreItemID? {
        guard let slot else { return nil }
        return SelectionRederivation.item(at: slot, in: score, preferringNoteIndex: nil)
    }

    /// The voice slot an item occupies. Tuplet brackets (and clefs, which never reach the selection) don't name a
    /// single slot, so they resolve to `nil`.
    static func slot(of item: SheetMusicCore.ScoreItemID?) -> VoiceElementID? {
        switch item {
        case let .note(id): VoiceElementID(id)
        case let .rest(id): VoiceElementID(id)
        case .tuplet, .clef, .none: nil
        }
    }

    /// The `noteIndexInChord` of the current selection when it is a `.note` anchored at exactly `location`,
    /// so re-derivation can keep the caret on the same chord tone across edits that add/remove siblings.
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
    /// ← / →, post-command re-derivation) goes through here; only note input deliberately splits the two, via
    /// `place(selection:caret:)`. Internal (not private) so the ops extensions in sibling files can drive selection.
    func select(_ item: SheetMusicCore.ScoreItemID?) {
        place(selection: item, caret: item)
    }

    /// Sets selection and caret independently and notifies. The only caller that passes different values is note
    /// input, which leaves the selection on the note it just wrote and moves the caret to the next slot.
    func place(selection item: SheetMusicCore.ScoreItemID?, caret: SheetMusicCore.ScoreItemID?) {
        selection = item.map(ScoreSelection.single) ?? .none
        selectedItem = item
        caretItem = caret
        armFromSelectionIfNeeded()
        onSelectionChanged(selection, caret)
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
}

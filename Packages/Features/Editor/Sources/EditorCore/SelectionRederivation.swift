import Domain
import Foundation

// Imported by name, and every `ScoreItemID` below is qualified, because Domain declares a DIFFERENT `ScoreItemID`:
// a library item's identifier. Domain re-exports SheetMusicCore, so both are in scope under a bare `import Domain`
// and the Domain one wins — silently, since the two are unrelated types and the error surfaces as "no member
// .note/.rest" a few lines away from the cause.
import SheetMusicCore

/// Maps the engine's post-mutation `lastAffectedLocation` back to a selectable item against the CURRENT
/// score. Positional `VoiceElementID`s drift with every mutation (splices shift indices, undo restores a
/// stale shape at a live index, …), so selection can never be carried forward as a stored identity — it
/// must be re-derived from the score after each command, undo, or redo.
public enum SelectionRederivation {
    /// - A chord slot with notes re-derives to `.note`, preferring `previousNoteIndex` (clamped to the
    ///   chord's current note count) so a selection anchored inside a chord survives edits that add or
    ///   remove sibling notes without jumping to note 0.
    /// - An empty chord (a rest — see `VoiceElement`'s doc: rests have no separate case) re-derives to
    ///   `.rest`.
    /// - A non-timed element (clef / key sig / time sig / barline / …) or an out-of-range location
    ///   re-derives to `nil` — e.g. undoing an input at a slot that a later edit spliced away.
    public static func item(
        at location: VoiceElementID,
        in score: Score,
        preferringNoteIndex previousNoteIndex: Int?,
    ) -> SheetMusicCore.ScoreItemID? {
        guard case let .chord(chord)? = score[location] else { return nil }
        guard !chord.notes.isEmpty else {
            return .rest(RestID(
                staff: location.staff,
                measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex,
            ))
        }
        let noteIndex = min(previousNoteIndex ?? 0, chord.notes.count - 1)
        return .note(NoteID(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elementIndex: location.elementIndex,
            noteIndexInChord: noteIndex,
        ))
    }
}

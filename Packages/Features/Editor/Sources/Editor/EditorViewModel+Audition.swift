import Domain
import Foundation
import SheetMusicCore

/// Fire-and-forget pitch preview on note input and pitch change — spec §5.6. Called by the pad's mutating ops
/// (`EditorViewModel+Input.swift`, `+Pitch.swift`, `+ChordTieTuplet.swift`) after `.inputNote`, `.writeNote`,
/// `.setNotePitch` (keys + drag), `.setAccidental` and `.addNoteToChord`. NOT called after delete / duration / tie /
/// tuplet — those don't produce a "resulting pitch" worth sounding.
extension EditorViewModel {
    /// Sounds `noteID` in the CURRENT edited score for 0.5 s through the `NoteAuditioning` seam. Nil-safe when no
    /// controller was injected or no session is active. Stores the spawned `Task` in `auditionTask` so tests can
    /// deterministically `await vm.auditionTask?.value` instead of racing a fire-and-forget call.
    func audition(_ noteID: NoteID) {
        guard let audition, let score else { return }
        auditionTask = Task {
            await audition.playPreview(noteID: noteID, in: score, duration: 0.5)
        }
    }

    /// Call-site helper for the pitch-changing ops: auditions the current `.note` selection, but only when
    /// `apply(_:)` actually mutated the score (`generation` advanced past `previousGeneration`). A refused edit
    /// (e.g. an out-of-range shift) leaves nothing to sound.
    func auditionSelectedNote(unlessStillAt previousGeneration: Int) {
        guard generation != previousGeneration, case let .note(noteID)? = selectedItem else { return }
        audition(noteID)
    }
}

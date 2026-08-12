import Domain
import Foundation
import SheetMusicCore

/// Fire-and-forget pitch preview on note input and pitch change — spec §5.6.
///
/// The core decides WHICH note should sound and when (`pendingAudition`, set by the ops after `.inputNote`,
/// `.writeNote`, `.setNotePitch`, `.setAccidental` and `.addNoteToChord` — never after delete / duration / tie /
/// tuplet, which produce no "resulting pitch" worth sounding). Making the sound is this side's job, because it needs
/// an audio session and a `Task`, and the core has neither.
extension EditorViewModel {
    /// Drains whatever the last op decided to preview and sounds it for 0.5 s through the `NoteAuditioning` seam.
    /// Nil-safe when nothing is pending, no controller was injected, or no session is active. Stores the spawned
    /// `Task` in `auditionTask` so tests can deterministically `await vm.auditionTask?.value` instead of racing a
    /// fire-and-forget call.
    func performPendingAudition() {
        guard let noteID = core.takePendingAudition(), let audition, let score = core.score else { return }
        auditionTask = Task {
            await audition.playPreview(noteID: noteID, in: score, duration: 0.5)
        }
    }
}

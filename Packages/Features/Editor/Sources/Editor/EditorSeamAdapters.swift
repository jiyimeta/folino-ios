import Domain
import EditorCore
import Foundation
import SheetMusicCore

/// Adapts the Reader's full playback controller down to the one method editing uses. The core auditions a note; it
/// has no business holding a handle to the audio session, the cursor stream or the per-staff mixer.
struct PlaybackAudition: NoteAuditioning {
    let controller: any PlaybackController

    func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) async {
        await controller.playPreview(noteID: noteID, in: score, duration: duration)
    }
}

/// Adapts the gateway + repository pair the App wires in. The core decides WHERE and IN WHAT FORMAT a score is saved
/// (`saveDestination`); this performs the write and refreshes the library row.
///
/// `@MainActor` because `ScoreLibraryRepository` is an `Observable` class the library list observes, so touching it
/// off the main actor is a data race. The protocol itself stays un-isolated: Android's implementation writes through
/// Room from whatever thread the JNI call arrived on, and forcing it onto a main thread it does not have would be
/// this platform's accident, not a rule.
@MainActor
struct GatewayScoreWriter: ScoreFileWriting {
    let gateway: any ScoreFileGateway
    let repository: any ScoreLibraryRepository

    func write(_ score: Score, to url: URL, format: ScoreFormat) async throws {
        try await gateway.saveScore(score, fileURL: url, format: format)
    }

    func refreshRow(_ item: ScoreItem) async throws {
        try await repository.saveScoreItem(item)
    }
}

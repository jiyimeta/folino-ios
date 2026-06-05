import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

extension LivePlaybackController {
    public func playPreview(noteID: NoteID, duration: TimeInterval) {
        // Thin pass-through to the engine's single-note preview. No-op until a score is loaded; the engine resolves the
        // NoteID against it and schedules its own note-off, so this returns immediately. The "only while not playing"
        // policy lives in the Reader (ReaderPlaybackSession) — the adapter stays a faithful forward.
        guard let score = loadedScore else { return }
        engine.playPreview(noteID: noteID, in: score, duration: duration)
    }
}

// PARITY(macos): note preview forwarding — depends on the gated LivePlaybackController; ports once that type does.

#if os(iOS)
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

    /// Editing-mode preview: the caller's score carries the fresh pitches; the engine's sampler graph (built at
    /// load time) is still addressable because v1 editing never changes the staff count.
    public func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) {
        engine.playPreview(noteID: noteID, in: score, duration: duration)
    }
}
#endif

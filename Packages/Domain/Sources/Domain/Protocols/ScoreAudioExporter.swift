import Foundation
import SheetMusicCore

/// Renders a `Score` to an audio file at `url`. Implementations
/// run an offline AVAudioEngine pass via `swift-sheet-music`'s
/// `PlaybackEngine.exportAudioFile`. The protocol surface is
/// Foundation-only — codec / bitrate / sample-rate choices live
/// inside the implementation so Domain stays free of
/// `SheetMusicAudio` types.
///
/// Errors thrown:
/// - `DomainError.scoreWriteFailed(reason:)` — every failure mode
///   (missing soundfont, engine setup, file write) is funnelled
///   through this case so the Library's existing error-alert
///   plumbing can render the message verbatim.
/// - `CancellationError` — if the calling Task is cancelled
///   mid-render.
public protocol ScoreAudioExporter: Sendable {
    /// Render `score` and write the resulting `.m4a` to `url`. The
    /// caller picks the destination path; the implementation
    /// overwrites any pre-existing file at that URL.
    func exportM4A(score: Score, to url: URL) async throws
}

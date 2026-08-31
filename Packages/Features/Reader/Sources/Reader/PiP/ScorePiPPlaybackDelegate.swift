// PARITY(macos): implements `AVPictureInPictureSampleBufferPlaybackDelegate`, which is iOS/tvOS-only — see the
//   marker on `ScorePiPCoordinator.swift`.

#if os(iOS)
import AVFoundation
import AVKit
import CoreMedia
import Foundation

@MainActor
final class ScorePiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Returns the app's current play state — the system pause/play glyph mirrors this. Coordinator wires it to the
    /// ViewModel.
    var isAppPlaying: () -> Bool = { false }
    /// True only between `didStartPiP` and `didStopPiP`. Before PiP is fully running we report "not paused" regardless
    /// of the app's real state — AVKit refuses to start PiP on a live source that reports paused at start time. Once
    /// PiP is up, mirror reality.
    var isPiPActive = false
    /// Fired when the user taps the PiP play/pause control. Passes the new desired state (true = play, false = pause).
    var onSetPlaying: (Bool) -> Void = { _ in }
    /// Fired when the user taps the ±10s skip control in PiP. Forwarded to the playback engine's skip API.
    var onSkip: (TimeInterval) -> Void = { _ in }
    /// Total score duration in seconds. Used for the PiP scrubber's time range — finite range hides AVKit's "LIVE"
    /// badge.
    var totalTimeSeconds: () -> TimeInterval = { 0 }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController, setPlaying playing: Bool,
    ) {
        Task { @MainActor in self.onSetPlaying(playing) }
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        didTransitionToRenderSize _: CMVideoDimensions,
    ) {
        // PiP window resize. We render at a fixed aspect ratio per session, so AVKit's letterbox handles the on-screen
        // scaling.
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        skipByInterval interval: CMTime,
        completion completionHandler: @escaping () -> Void,
    ) {
        let seconds = CMTimeGetSeconds(interval)
        Task { @MainActor in self.onSkip(seconds) }
        completionHandler()
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _: AVPictureInPictureController,
    ) -> CMTimeRange {
        // Finite range = AVKit drops the "LIVE" badge and shows a real scrubber. Duration comes from the loaded score;
        // floor at 1s so the range is never degenerate before the score finishes loading.
        let total = MainActor.assumeIsolated { totalTimeSeconds() }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(1, total), preferredTimescale: 600),
        )
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _: AVPictureInPictureController,
    ) -> Bool {
        MainActor.assumeIsolated {
            isPiPActive ? !isAppPlaying() : false
        }
    }
}
#endif

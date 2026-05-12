import AVFoundation
import AVKit
import CoreMedia
import Foundation

@MainActor
final class ScorePiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Mirror of "is the system PiP control showing pause?". We do not
    /// forward this to the app's playback engine — PiP is display-only.
    /// The user toggles real playback via the main app chrome.
    var isPlaying = true

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool,
    ) {
        Task { @MainActor in self.isPlaying = playing }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions,
    ) {
        // PiP window resize. We render at a fixed aspect ratio, so ignore.
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void,
    ) {
        // No-op: time scrubber is hidden via `pictureInPictureControllerTimeRangeForPlayback`.
        completionHandler()
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController,
    ) -> CMTimeRange {
        // `positiveInfinity` is the AVKit-documented way to indicate
        // a live source with no timeline — hides the seek scrubber.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController,
    ) -> Bool {
        // Best-effort: access the actor-isolated property synchronously.
        // For our display-only adapter, returning a stale value for one
        // tick is acceptable. If this becomes a problem, mirror the
        // state into a `nonisolated(unsafe)` shadow var.
        MainActor.assumeIsolated { !self.isPlaying }
    }
}

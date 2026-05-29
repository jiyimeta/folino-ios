import AVFoundation
import AVKit
import CoreMedia
import QuartzCore
import SheetMusicCore
import UIKit

@MainActor
final class ScorePiPCoordinator: NSObject {
    private static let framesPerSecond = 60
    /// At least once per ~1s, re-enqueue even if the cursor is unchanged so AVKit doesn't stall on its sample buffer
    /// queue.
    private static let forceEnqueueInterval = framesPerSecond

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Fires when AVKit starts presenting the PiP window — either via our explicit `dismissIfActive`/system foreground
    /// or via the `canStartPictureInPictureAutomaticallyFromInline` auto-start when the app backgrounds. The Reader VM
    /// uses this to mirror `isPiPActive`.
    var onPiPStarted: (() -> Void)?
    /// Called when the user dismisses the PiP window from the system UI. The Reader ViewModel uses this to flip its
    /// `isPiPActive` flag.
    var onPiPStopped: (() -> Void)?
    /// Snapshot of the app's current play state for the system PiP pause/play glyph.
    var isAppPlayingProvider: () -> Bool = { false } {
        didSet { delegate.isAppPlaying = isAppPlayingProvider }
    }

    /// Fires when the user taps the PiP play/pause control. The closure receives the new desired state and is expected
    /// to drive the Reader's playback engine if it doesn't already match.
    var onSetPlaying: (Bool) -> Void = { _ in } {
        didSet { delegate.onSetPlaying = onSetPlaying }
    }

    /// Fires when the user taps the ±10s skip control. Closure receives the seconds delta (negative for skip-back).
    var onSkip: (TimeInterval) -> Void = { _ in } {
        didSet { delegate.onSkip = onSkip }
    }

    /// Current playback position in seconds. Drives the PiP scrubber.
    var currentTimeProvider: () -> TimeInterval = { 0 }
    /// Total score duration in seconds. Drives the scrubber's right edge.
    var totalTimeProvider: () -> TimeInterval = { 0 } {
        didSet { delegate.totalTimeSeconds = totalTimeProvider }
    }

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var renderer: ScorePiPFrameRenderer?
    private let delegate = ScorePiPPlaybackDelegate()
    private var displayLink: CADisplayLink?

    private var currentCursor: ScoreCursor?
    private var lastEnqueuedCursorHash: Int?
    private var ticksSinceLastForceEnqueue = 0
    private var lastReportedPaused: Bool?
    private var lastReportedTotalTime: TimeInterval?

    /// Called once when the SwiftUI host view installs its display layer. The PiP controller is built here and reused
    /// across start/stop cycles — `AVPictureInPictureController.ContentSource` can't be re-attached to a display layer
    /// it has already seen without triggering the AVKit "Expect this to only be set once" warning and a follow-up
    /// crash.
    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        if self.displayLayer === displayLayer, pipController != nil { return }
        self.displayLayer = displayLayer
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: delegate,
        )
        let controller = AVPictureInPictureController(contentSource: source)
        // Auto-start defaults to off; the Reader flips this based on the user's Settings toggle via
        // `setAutoStartFromBackground`.
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.delegate = self
        pipController = controller

        // Drive the layer's playback clock manually so the AVKit scrubber follows the engine's actual position. Rate
        // stays at 0; we update the timebase's time per pump tick from `currentTimeProvider`. Without this, the layer's
        // default timebase treats every sample's PTS as "in the future" and queues frames instead of presenting them —
        // scrubber stays stuck at the trailing edge.
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        if let tb {
            CMTimebaseSetTime(tb, time: .zero)
            // Rate 0 = manually driven; pumpTick advances it to match the engine's reported position.
            CMTimebaseSetRate(tb, rate: 0)
            displayLayer.controlTimebase = tb
        }
    }

    /// Sets whether AVKit may present PiP automatically when the app backgrounds. Wired to the user's Settings toggle.
    func setAutoStartFromBackground(_ enabled: Bool) {
        pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    /// Arm the coordinator with a loaded score so AVKit's auto-start has frames ready when the app backgrounds. The
    /// pump runs while armed. Safe to call again to swap in a new score, staff size, or rest-collapse policy (e.g. when
    /// the user hides a staff, changes a clef override, resizes via Visual Inspector, or toggles multi-measure rest
    /// collapse); the existing pump and queued samples are torn down first. Async so the `LayoutEngine.layout` step
    /// runs on a detached task — every rearm (staff hide/show, clef change, resize) would otherwise burn ~100ms of
    /// main-actor time before the next Reader frame can paint.
    func arm(
        score: Score,
        staffSize: CGFloat,
        playbackCursor: ScoreCursor?,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
    ) async throws {
        guard let displayLayer else {
            throw NSError(
                domain: "ScorePiPCoordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display layer attached"],
            )
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            try ScorePiPFrameRenderer.prepare(
                score: score,
                staffSize: staffSize,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
                showInvisibleElements: showInvisibleElements,
            )
        }.value
        try Task.checkCancellation()
        stopPump()
        renderer = try ScorePiPFrameRenderer(score: score, prepared: prepared)
        currentCursor = playbackCursor
        lastEnqueuedCursorHash = nil
        ticksSinceLastForceEnqueue = 0
        lastReportedPaused = nil
        lastReportedTotalTime = nil
        // Clear queued frames sized for the previous score; the new renderer's pool may have different dimensions.
        displayLayer.flush()
        if let tb = displayLayer.controlTimebase {
            CMTimebaseSetTime(tb, time: .zero)
        }

        startPump()
        pumpTick() // seed the layer so AVKit has a frame at auto-start
    }

    /// Stop pumping and release the renderer. Does NOT dismiss an already-presenting PiP window — for that, call
    /// `dismissIfActive` first.
    func disarm() {
        stopPump()
        renderer = nil
        lastReportedPaused = nil
        lastReportedTotalTime = nil
        lastEnqueuedCursorHash = nil
        ticksSinceLastForceEnqueue = 0
        displayLayer?.flush()
        if let tb = displayLayer?.controlTimebase {
            CMTimebaseSetTime(tb, time: .zero)
        }
    }

    /// Tell AVKit to dismiss the PiP window if one is active. No-op otherwise. The `didStopPictureInPicture` callback
    /// runs as a result; the VM's `onPiPStopped` fires from there.
    func dismissIfActive() {
        if delegate.isPiPActive {
            pipController?.stopPictureInPicture()
        }
    }

    func updatePlaybackCursor(_ cursor: ScoreCursor?) {
        currentCursor = cursor
    }

    private func startPump() {
        let link = CADisplayLink(target: self, selector: #selector(pumpTickObjC))
        link.preferredFramesPerSecond = Self.framesPerSecond
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopPump() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func pumpTickObjC() {
        pumpTick()
    }

    private func pumpTick() {
        guard let renderer, let displayLayer else { return }
        // Recover from a transient failed state by flushing the queue; continuing to enqueue on a failed layer crashes
        // AVKit. If the recovery doesn't take, fall through to the normal pump — the layer will surface another failure
        // and stop() runs cleanly.
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        // AVKit doesn't poll the delegate — push an invalidation when either the paused state OR the total-time range
        // we'd report has changed since AVKit last queried us. Covers:
        //  • app-side play/pause changes,
        //  • `isPiPActive` transient flip during PiP startup,
        //  • the engine populating `totalTimeSeconds` after `prepare`.
        let paused = delegate.isPiPActive && !delegate.isAppPlaying()
        let total = totalTimeProvider()
        let pausedChanged = paused != lastReportedPaused
        let totalChanged = total != lastReportedTotalTime
        if pausedChanged || totalChanged {
            pipController?.invalidatePlaybackState()
            lastReportedPaused = paused
            lastReportedTotalTime = total
        }
        // Drive the display layer's playback clock from the engine so AVKit's scrubber tracks playback position. Only
        // advance while playing — when the engine is paused, holding the timebase steady AND not enqueueing redundant
        // same-PTS frames keeps the layer in a healthy state. Without this gate, the repeated identical samples
        // accumulate and the layer eventually drops into `.failed`.
        let isPlaying = delegate.isAppPlaying()
        if isPlaying, let tb = displayLayer.controlTimebase {
            CMTimebaseSetTime(
                tb,
                time: CMTime(seconds: currentTimeProvider(), preferredTimescale: 600),
            )
        }
        let hash = currentCursor?.hashValue ?? -1
        ticksSinceLastForceEnqueue += 1

        let cursorChanged = hash != lastEnqueuedCursorHash
        // Only force-enqueue while playing — pushing identical samples at a paused timebase corrupts the layer (see
        // comment above).
        let forceEnqueue = isPlaying
            && ticksSinceLastForceEnqueue >= Self.forceEnqueueInterval
        let scrolling = renderer.isAnimatingScroll

        guard cursorChanged || forceEnqueue || scrolling else { return }
        guard displayLayer.isReadyForMoreMediaData else { return }
        guard let buffer = renderer.renderFrame(playbackCursor: currentCursor)
        else { return }

        enqueue(buffer, displayLayer: displayLayer)
        lastEnqueuedCursorHash = hash
        ticksSinceLastForceEnqueue = 0
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, displayLayer: AVSampleBufferDisplayLayer) {
        var fmt: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt,
        )
        guard fmtStatus == noErr, let fmt else { return }

        // PTS tracks the engine's playback position so the AVKit scrubber mirrors what the user hears. When playback is
        // paused, the engine reports the same value across ticks → AVKit treats the stream as stalled and freezes the
        // scrubber, which matches reality.
        let pts = CMTime(
            seconds: currentTimeProvider(), preferredTimescale: 600,
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid,
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sample,
        )
        guard status == noErr, let sample else { return }

        // Display each frame on arrival regardless of how the layer's controlTimebase has drifted. Without this
        // attachment, samples pushed while the engine is paused (cursor still emitting residual onset events) stack up
        // in the queue with PTSs ahead of the frozen timebase; when the engine resumes the layer gets confused and
        // never recovers. Scrubber sync is handled separately via CMTimebaseSetTime in pumpTick, which AVKit reads
        // independently of sample timing.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true,
        ) as? [CFMutableDictionary], let attach = attachments.first {
            CFDictionarySetValue(
                attach,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
        displayLayer.enqueue(sample)
    }
}

extension ScorePiPCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _: AVPictureInPictureController,
    ) {
        Task { @MainActor in
            self.delegate.isPiPActive = false
            self.onPiPStopped?()
            // The pump stays running — it's tied to the armed state (set up by `arm`, torn down by `disarm`), not to
            // whether a PiP session is currently presenting. Stopping the pump here would leave AVKit's next auto-start
            // without frames.
        }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _: AVPictureInPictureController,
    ) {}

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _: AVPictureInPictureController,
    ) {
        Task { @MainActor in
            self.delegate.isPiPActive = true
            self.onPiPStarted?()
        }
    }

    nonisolated func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError _: Error,
    ) {
        // AVKit surfaces start failures here. We deliberately don't log — a failure flips the user-visible toggle back
        // via the same path as a user dismiss (didStop fires anyway in practice).
    }
}

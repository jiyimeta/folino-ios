import AVFoundation
import AVKit
import CoreMedia
import QuartzCore
import SheetMusicCore
import UIKit

@MainActor
final class ScorePiPCoordinator: NSObject {
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Called when the user dismisses the PiP window from the system UI.
    /// The Reader ViewModel uses this to flip its `isPiPActive` flag.
    var onPiPStopped: (() -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var renderer: ScorePiPFrameRenderer?
    private let delegate = ScorePiPPlaybackDelegate()
    private var displayLink: CADisplayLink?

    private var currentCursor: ScoreCursor?
    private var lastEnqueuedCursorHash: Int?
    private var ticksSinceLastForceEnqueue = 0

    private let pixelSize = CGSize(width: 1280, height: 360)
    private let framesPerSecond = 20
    private static let forceEnqueueInterval = 20 // ~1s at 20fps

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func start(score: Score, staffSize: CGFloat, playbackCursor: ScoreCursor?) throws {
        guard let displayLayer else {
            throw NSError(
                domain: "ScorePiPCoordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display layer attached"],
            )
        }
        renderer = try ScorePiPFrameRenderer(
            score: score, staffSize: staffSize, pixelSize: pixelSize,
        )
        currentCursor = playbackCursor
        lastEnqueuedCursorHash = nil
        ticksSinceLastForceEnqueue = 0

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: delegate,
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller

        startPump()
        pumpTick() // ensure first frame is enqueued

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        pipController?.stopPictureInPicture()
        pipController = nil
        stopPump()
        renderer = nil
        displayLayer?.flush()
    }

    func updatePlaybackCursor(_ cursor: ScoreCursor?) {
        currentCursor = cursor
    }

    private func startPump() {
        let link = CADisplayLink(target: self, selector: #selector(pumpTickObjC))
        link.preferredFramesPerSecond = framesPerSecond
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
        let hash = currentCursor?.hashValue ?? -1
        ticksSinceLastForceEnqueue += 1

        let cursorChanged = hash != lastEnqueuedCursorHash
        let forceEnqueue = ticksSinceLastForceEnqueue >= Self.forceEnqueueInterval

        guard cursorChanged || forceEnqueue,
              displayLayer.isReadyForMoreMediaData,
              let buffer = renderer.renderFrame(playbackCursor: currentCursor)
        else { return }

        enqueue(buffer, displayLayer: displayLayer)
        lastEnqueuedCursorHash = hash
        ticksSinceLastForceEnqueue = 0
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, displayLayer: AVSampleBufferDisplayLayer) {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt,
        )
        guard let fmt else { return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)),
            presentationTimeStamp: now,
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
        displayLayer.enqueue(sample)
    }
}

extension ScorePiPCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController,
    ) {
        Task { @MainActor in
            self.stopPump()
            self.onPiPStopped?()
        }
    }
}

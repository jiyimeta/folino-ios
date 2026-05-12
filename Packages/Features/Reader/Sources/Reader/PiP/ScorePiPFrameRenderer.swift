import CoreGraphics
import CoreVideo
import QuartzCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI

/// Renders a horizontal-mode frame of the score directly into a
/// `CVPixelBuffer` via Core Graphics. No SwiftUI / UIKit / window
/// dependency — `ScoreLayerBuilder.buildSystem(...)` produces a
/// `CALayer` we can `render(in:)` into any CGContext, including
/// off-screen pixel-buffer-backed ones.
///
/// Horizontal layout is single-system, so we lay out once at init,
/// build the system layer once, and per-frame just blit + draw the
/// cursor rectangle on top.
@MainActor
final class ScorePiPFrameRenderer {
    /// Distance in pt from the left edge of the PiP window at which the
    /// cursor's measure is parked when playback is running.
    private static let cursorLeadingInsetPt: CGFloat = 80
    /// Vertical breathing room above & below the system inside the
    /// PiP window.
    private static let verticalPaddingPt: CGFloat = 16

    let pixelSize: CGSize

    private let score: Score
    private let pool: CVPixelBufferPool
    private let document: LayoutDocument
    private let system: LayoutSystem
    private let scoreLayer: CALayer

    init(score: Score, staffSize: CGFloat) throws {
        self.score = score

        let opts = ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: .ignoreAll,
            showBreakIndicators: false,
        )
        let naturalWidth = LayoutEngine.naturalContentWidth(score: score, options: opts)
        document = LayoutEngine.layout(
            score: score, options: opts, availableWidth: naturalWidth,
        )
        guard let firstSystem = document.systems.first else {
            throw NSError(
                domain: "ScorePiPFrameRenderer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Layout produced no systems"],
            )
        }
        system = firstSystem

        // Adaptive PiP buffer size: height grows with the system (so
        // 4-staff scores aren't crammed into a narrow strip), width
        // chosen for an aspect ratio that yields ~4 measures across
        // for single-staff content and ~2 measures for orchestral.
        // Floor at 480×270 (16:9, AVKit-friendly minimum) — too-small
        // buffers can stall the PiP system on some devices.
        let staffCount = max(1, firstSystem.staffOrigins.count)
        let rawHeight = ceil(firstSystem.size.height + Self.verticalPaddingPt * 2)
        let pixelHeight = max(270, rawHeight)
        let aspect = max(16.0 / 9.0, 4.0 / CGFloat(staffCount))
        let pixelWidth = max(480, ceil(pixelHeight * aspect))
        // AVSampleBufferDisplayLayer accepts odd pixel sizes, but we round
        // up to even for safety with downstream video pipelines.
        pixelSize = CGSize(
            width: Self.roundUpToEven(pixelWidth),
            height: Self.roundUpToEven(pixelHeight),
        )

        pool = try Self.makePool(size: pixelSize)
        scoreLayer = ScoreLayerBuilder.buildSystem(firstSystem, metrics: document.metrics)
    }

    func renderFrame(playbackCursor: ScoreCursor?) -> CVPixelBuffer? {
        var maybe: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe) == kCVReturnSuccess,
              let buffer = maybe else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info,
        ) else { return nil }

        // White background — overdraws whatever the pool returns.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pixelSize))

        // CGContext default is bottom-left; CALayer & cursor frames are
        // top-left. Flip so positive Y goes downward.
        ctx.translateBy(x: 0, y: pixelSize.height)
        ctx.scaleBy(x: 1, y: -1)

        let cursorFrame = playbackCursor.flatMap {
            document.cursorFrame(for: $0, in: score)
        }
        let shiftX: CGFloat = cursorFrame
            .map { -$0.minX + Self.cursorLeadingInsetPt } ?? 0
        let shiftY = Self.verticalPaddingPt

        ctx.saveGState()
        ctx.translateBy(x: shiftX, y: shiftY)
        ctx.translateBy(x: system.origin.x, y: system.origin.y)
        scoreLayer.render(in: ctx)
        ctx.restoreGState()

        if let frame = cursorFrame {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.95, alpha: 0.25))
            ctx.fill(CGRect(
                x: frame.minX + shiftX,
                y: frame.minY + shiftY,
                width: frame.width,
                height: frame.height,
            ))
        }
        return buffer
    }

    private static func roundUpToEven(_ value: CGFloat) -> CGFloat {
        let n = Int(value.rounded(.up))
        return CGFloat(n + (n % 2))
    }

    private static func makePool(size: CGSize) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(
                domain: "ScorePiPFrameRenderer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPool create failed"],
            )
        }
        return pool
    }
}

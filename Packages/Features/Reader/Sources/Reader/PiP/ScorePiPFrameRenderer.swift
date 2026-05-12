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
/// cursor rectangle on top — fast and deterministic.
@MainActor
final class ScorePiPFrameRenderer {
    private static let cursorLeadingInsetPt: CGFloat = 80

    private let score: Score
    private let pixelSize: CGSize
    private let pool: CVPixelBufferPool
    private let document: LayoutDocument
    private let system: LayoutSystem
    private let scoreLayer: CALayer

    init(score: Score, staffSize: CGFloat, pixelSize: CGSize) throws {
        self.score = score
        self.pixelSize = pixelSize
        pool = try Self.makePool(size: pixelSize)

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

        // Horizontal shift: bring the cursor's measure to a fixed leading
        // inset. Without a cursor, anchor the score at x=0.
        let cursorFrame = playbackCursor.flatMap {
            document.cursorFrame(for: $0, in: score)
        }
        if let cursor = playbackCursor {
            print("[PiP] cursor=\(cursor) frame=\(cursorFrame ?? .zero)")
        }
        let shiftX: CGFloat = cursorFrame.map { -$0.minX + Self.cursorLeadingInsetPt } ?? 0
        // Vertical: centre the system in the PiP window. The system's
        // height is much smaller than 360pt for a single-staff score.
        let shiftY = max(0, (pixelSize.height - system.size.height) / 2)

        ctx.saveGState()
        ctx.translateBy(x: shiftX, y: shiftY)
        // The layer's internal (0,0) corresponds to the system's
        // top-left in document coords, so render at the system's origin.
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

import AVFoundation
import CoreVideo
import SheetMusicCore
import SwiftUI
import UIKit

/// SwiftUI off-screen rendering via `UIHostingController.layer.render(in:)`
/// produces blank output when the controller isn't attached to a window —
/// SwiftUI's display pass only runs against window-attached layers. We use
/// `ImageRenderer` instead, which is built for window-less rasterisation.
@MainActor
final class ScorePiPFrameRenderer {
    private let score: Score
    private let staffSize: CGFloat
    private let pixelSize: CGSize
    private let pool: CVPixelBufferPool

    init(score: Score, staffSize: CGFloat, pixelSize: CGSize) throws {
        self.score = score
        self.staffSize = staffSize
        self.pixelSize = pixelSize
        pool = try Self.makePool(size: pixelSize)
    }

    func renderFrame(playbackCursor: ScoreCursor?) -> CVPixelBuffer? {
        let canvas = PiPScoreCanvas(
            score: score, staffSize: staffSize, playbackCursor: playbackCursor,
        )
        .frame(width: pixelSize.width, height: pixelSize.height)
        .background(Color(.systemBackground))

        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(
            width: pixelSize.width, height: pixelSize.height,
        )
        renderer.scale = 1

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

        // CGContext origin is bottom-left; ImageRenderer produces a CGImage
        // with top-left origin. Flip Y so the score draws right-side-up.
        ctx.translateBy(x: 0, y: pixelSize.height)
        ctx.scaleBy(x: 1, y: -1)
        renderer.render { _, draw in draw(ctx) }
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

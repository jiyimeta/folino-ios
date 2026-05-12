import AVFoundation
import CoreVideo
import SheetMusicCore
import SwiftUI
import UIKit

@MainActor
final class ScorePiPFrameRenderer {
    private let pixelSize: CGSize
    private let pool: CVPixelBufferPool
    private let hostingController: UIHostingController<PiPScoreCanvas>

    init(score: Score, staffSize: CGFloat, pixelSize: CGSize) throws {
        self.pixelSize = pixelSize
        pool = try Self.makePool(size: pixelSize)
        let canvas = PiPScoreCanvas(
            score: score, staffSize: staffSize, playbackCursor: nil,
        )
        let hc = UIHostingController(rootView: canvas)
        hc.view.backgroundColor = .systemBackground
        hc.view.frame = CGRect(origin: .zero, size: pixelSize)
        if #available(iOS 16.4, *) { hc.safeAreaRegions = [] }
        hostingController = hc
    }

    func renderFrame(playbackCursor: ScoreCursor?) -> CVPixelBuffer? {
        let current = hostingController.rootView
        hostingController.rootView = PiPScoreCanvas(
            score: current.score,
            staffSize: current.staffSize,
            playbackCursor: playbackCursor,
        )
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

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
        hostingController.view.layer.render(in: ctx)
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

/// Stub — replaced in Task 2 with the real off-screen canvas.
struct PiPScoreCanvas: View {
    let score: Score
    let staffSize: CGFloat
    let playbackCursor: ScoreCursor?
    var body: some View {
        Color.clear
    }
}

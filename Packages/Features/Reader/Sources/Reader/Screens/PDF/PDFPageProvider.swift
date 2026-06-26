import CoreGraphics
import PDFKit
import UIKit

/// Rasterizes PDF pages to `CGImage` on demand and caches a sliding window of pages around the one most recently
/// requested. The reader draws the cached bitmap (cheap to blit) instead of re-running `drawPDFPage` every frame; on a
/// zoom commit the caller re-requests the visible page at the new scale, replacing the cached bitmap so content stays
/// crisp. Memory stays bounded by `windowRadius` regardless of document length.
@MainActor
final class PDFPageProvider {
    let pageCount: Int
    private let document: PDFDocument
    private let windowRadius: Int
    private struct Entry { var image: CGImage; var scale: CGFloat }
    private var cache: [Int: Entry] = [:]

    init(document: PDFDocument, windowRadius: Int = 2) {
        self.document = document
        self.windowRadius = max(0, windowRadius)
        pageCount = document.pageCount
    }

    func pageSize(_ index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return .zero }
        return page.bounds(for: .mediaBox).size
    }

    func image(pageIndex: Int, targetScale: CGFloat) -> CGImage? {
        guard pageIndex >= 0, pageIndex < pageCount else { return nil }
        evictOutsideWindow(center: pageIndex)
        let scale = max(0.1, targetScale)
        if let entry = cache[pageIndex], abs(entry.scale - scale) < 0.01 {
            return entry.image
        }
        guard let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: pixelSize))
            // Flip into PDF's bottom-left origin and scale points → pixels.
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: cg)
        }
        guard let cgImage = image.cgImage else { return nil }
        cache[pageIndex] = Entry(image: cgImage, scale: scale)
        return cgImage
    }

    func purge() {
        cache.removeAll()
    }

    private func evictOutsideWindow(center: Int) {
        let lo = center - windowRadius, hi = center + windowRadius
        for key in cache.keys where key < lo || key > hi {
            cache.removeValue(forKey: key)
        }
    }
}

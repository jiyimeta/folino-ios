import CoreGraphics
import PDFKit
@testable import Reader
import SwiftUI
import Testing

/// Guards the stroke weight of rendered PDF pages.
///
/// `PDFPage.draw(with:to:)` reads the device resolution off the context's `ctm`, which SwiftUI's
/// `GraphicsContext.withCGContext` reports as the identity, so it applies its 1×-legibility floor (~0.75pt) to every
/// thin stroke. Engraved sheet music draws staff lines at ~0.25pt, so that floor tripled them on screen. These tests
/// render through the real `PDFPageCanvas` and measure the ink a hairline actually deposits.
@MainActor
struct PDFPageRasterizerTests {
    /// Page geometry of the synthetic fixture, in points.
    private static let pageSize = CGSize(width: 200, height: 100)
    private static let hairlineWidth: CGFloat = 0.25
    private static let hairlineCount = 5

    /// A one-page PDF with `hairlineCount` horizontal `hairlineWidth`-pt rules across the middle.
    private func hairlinePDF() throws -> PDFPage {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(Self.hairlineWidth)
        for i in 0 ..< Self.hairlineCount {
            let y = 40 + CGFloat(i) * 5
            ctx.move(to: CGPoint(x: 10, y: y))
            ctx.addLine(to: CGPoint(x: 190, y: y))
        }
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()

        let document = try #require(PDFDocument(data: data as Data))
        return try #require(document.page(at: 0))
    }

    /// Total ink (in device pixels of coverage) deposited down a vertical slice through the middle of the rendered
    /// page. Coverage is `1 - luminance`, so a perfectly rendered 0.25pt rule at scale 3 contributes 0.75px.
    private func inkDownMiddleColumn(of page: PDFPage, scale: CGFloat) throws -> Double {
        let renderer = ImageRenderer(
            content: PDFPageCanvas(page: page).frame(width: Self.pageSize.width, height: Self.pageSize.height),
        )
        renderer.scale = scale
        let image = try #require(renderer.cgImage)

        let width = image.width, height = image.height
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let x = width / 2
        return (0 ..< height).reduce(0.0) { total, y in
            total + Double(255 - pixels[y * ctx.bytesPerRow + x * 4]) / 255.0
        }
    }

    @Test func `hairlines keep their true weight at 3x`() throws {
        let page = try hairlinePDF()
        let ink = try inkDownMiddleColumn(of: page, scale: 3)
        let expected = Double(Self.hairlineCount) * Double(Self.hairlineWidth) * 3
        // Anti-aliasing costs a few percent; `PDFPage.draw`'s legibility floor costs 200%.
        #expect(
            abs(ink - expected) < expected * 0.2,
            "hairline ink was \(ink)px, expected ≈\(expected)px",
        )
    }

    @Test func `hairlines keep their true weight at 2x`() throws {
        let page = try hairlinePDF()
        let ink = try inkDownMiddleColumn(of: page, scale: 2)
        let expected = Double(Self.hairlineCount) * Double(Self.hairlineWidth) * 2
        #expect(
            abs(ink - expected) < expected * 0.2,
            "hairline ink was \(ink)px, expected ≈\(expected)px",
        )
    }
}

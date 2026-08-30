import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
import ReaderAnnotationCore
import UIKit

/// Stamps annotation ink onto a base PDF's pages and returns the new document's bytes.
///
/// Each page is rebuilt by replaying the base page's content stream with `CGContext.drawPDFPage` and drawing the
/// page's ink on top, which is what keeps the notation vector: `drawPDFPage` copies the page's own drawing commands
/// into the destination rather than rasterizing them, so glyphs stay glyphs and hairlines stay hairlines. Only the
/// ink is an image.
///
/// The ink itself goes through PencilKit — the same renderer `StaticInkLayer` uses for committed ink on screen — so
/// the exported marks look like the ones the user drew, including pressure taper and marker blending, with no second
/// ink renderer to keep in step. It is rasterized at `inkScale`, cropped to the ink's own bounds, so a page with one
/// circled bar costs a small image rather than a page-sized one.
@MainActor
enum AnnotatedPDFComposer {
    /// Rasterization factor for the ink image against the PDF's 72 dpi user space — 4× is ~288 dpi, enough for print.
    static let inkScale: CGFloat = 4

    /// - Parameters:
    ///   - basePDF: the document to stamp. Its pages, sizes and vector content are preserved.
    ///   - drawings: the stored anchors the placements index into.
    ///   - placements: from `AnnotatedExportPlanner`, in page-local coordinates (points, origin top-left, y down).
    /// - Returns: the composed document's bytes.
    /// - Throws: `DomainError.scoreWriteFailed` when `basePDF` cannot be read as a PDF, or when the destination
    ///   context cannot be created.
    static func compose(
        basePDF: Data,
        drawings: [DrawingAnchor],
        placements: [InkPlacement],
    ) throws -> Data {
        guard let provider = CGDataProvider(data: basePDF as CFData),
              let source = CGPDFDocument(provider), source.numberOfPages > 0
        else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: base PDF is unreadable")
        }
        // PDFKit is used only to replay annotations the base file already carries (a highlight made in another app,
        // a form field's appearance); `drawPDFPage` replays the content stream alone. folino's own ink is not a PDF
        // annotation and never comes back through here.
        let pdfKitDocument = PDFDocument(data: basePDF)

        let inkByPage = Dictionary(grouping: placements, by: \.pageIndex)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: could not create the PDF context")
        }

        for pageNumber in 1 ... source.numberOfPages {
            guard let page = source.page(at: pageNumber) else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPDFPage([
                kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size),
            ] as CFDictionary)

            context.saveGState()
            context.drawPDFPage(page)
            context.restoreGState()

            if let pdfKitDocument, let kitPage = pdfKitDocument.page(at: pageNumber - 1) {
                for annotation in kitPage.annotations where annotation.shouldDisplay {
                    context.saveGState()
                    annotation.draw(with: .mediaBox, in: context)
                    context.restoreGState()
                }
            }

            if let placements = inkByPage[pageNumber - 1] {
                drawInk(placements, drawings: drawings, pageSize: box.size, into: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return out as Data
    }

    /// Builds this page's `PKDrawing` in page-local UIKit coordinates, rasterizes the ink's bounding box and draws it
    /// into the PDF page. The context is in PDF orientation (bottom-left origin, y up), so the image lands under a
    /// flip; everything above it is untouched by the flip because it is scoped to a `saveGState`.
    private static func drawInk(
        _ placements: [InkPlacement],
        drawings: [DrawingAnchor],
        pageSize: CGSize,
        into context: CGContext,
    ) {
        var strokes: [PKStroke] = []
        for placement in placements {
            guard placement.drawingIndex >= 0, placement.drawingIndex < drawings.count,
                  var stored = InkStrokePencilKitBridge.decodeStoredDrawing(
                      drawings[placement.drawingIndex].encodedDrawing,
                  )
            else { continue }
            let transform = CGAffineTransform(scaleX: placement.transform.sp, y: placement.transform.sp)
                .concatenating(CGAffineTransform(
                    translationX: placement.transform.px, y: placement.transform.py,
                ))
            stored.transform(using: transform)
            strokes.append(contentsOf: InkStrokePencilKitBridge.bakingTransformIntoPoints(stored).strokes)
        }
        let drawing = PKDrawing(strokes: strokes)
        guard !drawing.strokes.isEmpty else { return }

        // Clip to the page and pad by a point so a stroke's rendered edge is not shaved off by the crop.
        let bounds = drawing.bounds.insetBy(dx: -1, dy: -1)
            .intersection(CGRect(origin: .zero, size: pageSize))
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Stored ink colors are canonical light-appearance sRGB; render under the light trait so a dynamic color
        // inside a legacy PKDrawing archive cannot come out dark-adapted on a white page.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: inkScale)
        }
        guard let cgImage = image?.cgImage else { return }

        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}

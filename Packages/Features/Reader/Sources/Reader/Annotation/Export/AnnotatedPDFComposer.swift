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
            // `source.page(at:)` cannot actually return nil here — `pageNumber` never leaves the
            // already-validated `1...source.numberOfPages` range `CGPDFDocument` reports for itself — but the
            // API is optional-returning, so this stays a defensive skip rather than a force-unwrap.
            guard let page = source.page(at: pageNumber) else { continue }

            // The destination page is declared at a clean zero origin, sized to match the source's own media
            // box. A PDF's MediaBox may legally carry a non-zero origin; the Reader's own page geometry
            // (`PagedPDFContainer`, `PDFPageView`, `VerticalPDFContainer`) never references that origin — it
            // treats a page as size-only — so pinning the destination to zero keeps this composer's `pageSize`
            // and the ink math in `drawInk` (both already origin-agnostic) in the same frame the Reader itself
            // anchored the ink against, rather than importing the source box's own coordinate system.
            var destinationBox = CGRect(origin: .zero, size: page.getBoxRect(.mediaBox).size)
            context.beginPDFPage([
                kCGPDFContextMediaBox as String: Data(bytes: &destinationBox, count: MemoryLayout<CGRect>.size),
            ] as CFDictionary)

            // `drawPDFPage` replays only the content stream — it does not honor the page's `/Rotate` entry, so
            // an un-adjusted call would draw a rotated source page sideways. `getDrawingTransform` supplies
            // exactly the rotation (and, for a source box whose aspect doesn't match its rotated content, the
            // same fit/letterbox) CoreGraphics itself applies when presenting the page — mirroring what
            // `PDFPageRasterizer` already does for the on-screen page (`PDFPageRasterizer.swift:36-39`), which
            // is also what the Reader anchored the ink against. So the exported page keeps the same frame the
            // ink was placed relative to. For an unrotated page (`/Rotate` absent or 0) this is the identity.
            context.saveGState()
            context.concatenate(page.getDrawingTransform(
                .mediaBox, rect: destinationBox, rotate: 0, preserveAspectRatio: true,
            ))
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
                drawInk(placements, drawings: drawings, pageSize: destinationBox.size, into: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return out as Data
    }

    /// Builds this page's `PKDrawing` in page-local UIKit coordinates, rasterizes the ink's bounding box and draws it
    /// into the PDF page. The context is in PDF orientation (bottom-left origin, y up), so the destination rect is
    /// converted from `bounds`' top-left / y-down frame rather than flipping the CTM — see the comment at the
    /// `draw(cgImage:in:)` call below for why.
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

        // The PDF context is bottom-left / y-up; `bounds` is top-left / y-down. Convert the rect rather than
        // flipping the CTM: `draw(_:in:)` puts the image's first row at the rect's max-y in USER space, so a
        // flipped CTM positions the box correctly but mirrors the image inside it.
        let inkRect = CGRect(
            x: bounds.minX, y: pageSize.height - bounds.maxY,
            width: bounds.width, height: bounds.height,
        )
        context.draw(cgImage, in: inkRect)
    }
}

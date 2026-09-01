import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
import ReaderAnnotationCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The bezier-path and color types PDFKit and PencilKit speak on this platform.
//
// Only the handoff is platform-bound: `PDFAnnotation.add(_:)` takes a `UIBezierPath` on iOS and an `NSBezierPath`
// on macOS with no common overload, and `PKInk.color` is likewise `UIColor` / `NSColor`. The stroke geometry is
// built once as a `CGPath` and converted at that boundary, so the placement math keeps a single copy.
#if canImport(UIKit)
private typealias PlatformBezierPath = UIBezierPath
private typealias PlatformColor = UIColor
#else
private typealias PlatformBezierPath = NSBezierPath
private typealias PlatformColor = NSColor
#endif

/// Stamps annotation ink onto a base PDF's pages as PDF ink annotations and returns the new document's bytes.
///
/// Each placed stroke becomes its own `PDFAnnotation` of subtype `.ink`, added to its destination page. The base
/// document's own pages, sizes, content streams and existing annotations are never touched — nothing rewrites the
/// page body any more. That is what makes the ink erasable as a first-class PDF object in any PDF editor, on any
/// device, rather than a raster the app itself baked into the page.
///
/// The appearance is drawn as vector, from the placed stroke's own per-point geometry — a `CGPath` built by
/// walking the decoded (and placed) `PKStroke`'s points — rather than by rasterizing through PencilKit.
/// `PKDrawing.image(from:scale:)` proved unusable on device: it returned a fully transparent raster for the user's
/// own strokes, and twelve hypotheses (invocation style, every tool, color, storage format, stroke mask, point
/// count, timestamp collisions) were each falsified without finding the cause. Walking `PKStroke.path` and
/// `PKDrawing.transform(using:)` — the same geometry APIs the on-screen ink layer already relies on — is a
/// different, deterministic code path with no rasterizer involved, so it sidesteps the bug rather than working
/// around it. The visible cost is pressure taper and marker blending, which a single-width vector stroke
/// approximates rather than reproduces; monoline (a constant-width tool) is exact.
///
/// Nothing private is written alongside. An earlier revision carried the placed stroke's
/// `PKDrawing.dataRepresentation()` under Apple's own `/PPK` key, in the hope that Apple's markup tools would
/// adopt folino's ink as an editable PencilKit drawing. They do not: swapping only the `/PPK` container inside
/// one of Apple's own annotated PDFs showed its markup needs a private `crdt` container that no public PencilKit
/// route emits — `dataRepresentation()` produces a `wrd`-prefixed one — and imitating every other field Books
/// writes changed nothing. So the blob was inert here and cost roughly 21 KB per page, and it is gone. The
/// decoding of that container is a separate investigation; see `docs/engineering/crdt-ink-format/`.
///
/// The annotations are deliberately NOT locked (`/F` keeps PDFKit's default rather than Books' Print + Locked +
/// LockedContents). folino wants other editors to be able to select and delete these marks; Books locks its own
/// because the editable truth lives in the private payload, which is exactly the arrangement folino does not have.
@MainActor
enum AnnotatedPDFComposer {
    /// - Parameters:
    ///   - basePDF: the document to stamp. Its pages, sizes, vector content and existing annotations are preserved
    ///     unchanged; only new ink annotations are added.
    ///   - drawings: the stored anchors the placements index into.
    ///   - placements: from `AnnotatedExportPlanner`, in page-local coordinates (points, origin top-left, y down).
    /// - Returns: the composed document's bytes.
    /// - Throws: `DomainError.scoreWriteFailed` when `basePDF` cannot be read as a PDF, or when the composed
    ///   document cannot be re-serialized.
    static func compose(
        basePDF: Data,
        drawings: [DrawingAnchor],
        placements: [InkPlacement],
    ) throws -> Data {
        guard let document = PDFDocument(data: basePDF) else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: base PDF is unreadable")
        }

        for placement in placements {
            guard placement.pageIndex >= 0, placement.pageIndex < document.pageCount,
                  let page = document.page(at: placement.pageIndex),
                  let annotation = makeAnnotation(for: placement, drawings: drawings, page: page)
            else { continue }
            page.addAnnotation(annotation)
        }

        guard let data = document.dataRepresentation() else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: could not serialize the composed PDF")
        }
        return data
    }

    /// Decodes the placed drawing, bakes the placement's transform into its points (page-local, top-left origin,
    /// y-down — see `InkStrokePencilKitBridge.bakingTransformIntoPoints`), and builds one `.ink` annotation from the
    /// result. `nil` when the drawing index is out of range, the stored bytes don't decode, or the placed geometry
    /// collapses to nothing (clipped fully off the page).
    private static func makeAnnotation(
        for placement: InkPlacement, drawings: [DrawingAnchor], page: PDFPage,
    ) -> PDFAnnotation? {
        guard placement.drawingIndex >= 0, placement.drawingIndex < drawings.count,
              var stored = InkStrokePencilKitBridge.decodeStoredDrawing(
                  drawings[placement.drawingIndex].encodedDrawing,
              )
        else { return nil }

        let transform = CGAffineTransform(scaleX: placement.transform.sp, y: placement.transform.sp)
            .concatenating(CGAffineTransform(
                translationX: placement.transform.px, y: placement.transform.py,
            ))
        stored.transform(using: transform)
        let placed = InkStrokePencilKitBridge.bakingTransformIntoPoints(stored)
        guard let firstStroke = placed.strokes.first else { return nil }

        let pageSize = page.bounds(for: .mediaBox).size

        // `PKDrawing.bounds` already encloses the rendered ink (stroke width included), same as the raster
        // composition this replaced; pad by a point for anti-aliasing slack and clip to the page.
        let pageLocalBounds = placed.bounds.insetBy(dx: -1, dy: -1)
            .intersection(CGRect(origin: .zero, size: pageSize))
        guard pageLocalBounds.width > 0, pageLocalBounds.height > 0 else { return nil }

        // Annotation space is the page's own space with a bottom-left origin; `pageLocalBounds`, like every
        // placement, is page-local with a top-left origin and y down — flip the rect, not the points.
        let annotationBounds = CGRect(
            x: pageLocalBounds.minX, y: pageSize.height - pageLocalBounds.maxY,
            width: pageLocalBounds.width, height: pageLocalBounds.height,
        )

        // `PDFAnnotation.border.lineWidth` is a single width for the whole stroke; the median across every point
        // (not the mean) is the more faithful representative for a tapered stroke, where a few very thin or very
        // thick samples — the stroke's own start/end, a pressure spike — would otherwise pull a single width away
        // from what most of the stroke actually looks like.
        let widths = placed.strokes.flatMap { $0.path.map { CGFloat($0.size.width) } }
        let lineWidth = median(of: widths) ?? CGFloat(firstStroke.path.first?.size.width ?? 1)

        /// A path handed to `PDFAnnotation.add(_:)` is in the ANNOTATION's own space, not the page's: PDFKit adds
        /// `bounds.origin` back when it writes `/InkList`, and generates an appearance stream whose BBox is
        /// `[0 0 bounds.width bounds.height]`. So each point is flipped into the page's bottom-left space and then
        /// rebased onto `annotationBounds.origin`. Feeding page-space points straight in displaced every stroke by
        /// `bounds.origin` — off the page entirely for anything past the middle of it — and the appearance stream's
        /// own clip then swallowed whatever remained, which is why the ink rendered nowhere at all.
        func annotationPoint(_ pageLocal: CGPoint) -> CGPoint {
            CGPoint(
                x: pageLocal.x - annotationBounds.minX,
                y: (pageSize.height - pageLocal.y) - annotationBounds.minY,
            )
        }

        let annotation = PDFAnnotation(bounds: annotationBounds, forType: .ink, withProperties: nil)
        for stroke in placed.strokes {
            let points = Array(stroke.path)
            guard let first = points.first else { continue }
            let path = CGMutablePath()
            path.move(to: annotationPoint(first.location))
            for point in points.dropFirst() {
                path.addLine(to: annotationPoint(point.location))
            }
            annotation.add(PlatformBezierPath(cgPath: path))
        }
        annotation.color = color(of: firstStroke)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        return annotation
    }

    /// The annotation's color, folding the stroke's PencilKit opacity — a per-point translucency multiplier
    /// PencilKit applies at render time for tools like the marker, separate from the ink color's own alpha channel —
    /// into the color's alpha, since `PDFAnnotation` has no separate opacity property. Resolved under the light
    /// trait first: stored ink colors are canonical light-appearance sRGB, so a dynamic color inside a legacy
    /// `PKDrawing` archive must not come out dark-adapted on a white page.
    private static func color(of stroke: PKStroke) -> PlatformColor {
        let inkColor = stroke.ink.color
        guard let rgba = lightAppearanceRGBA(of: inkColor) else { return inkColor }
        let opacity = CGFloat(stroke.path.first?.opacity ?? 1)
        return PlatformColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a * opacity)
    }

    /// `color`'s one platform-bound step: resolve a possibly-dynamic ink color under the LIGHT appearance and read
    /// its sRGB components. iOS resolves through a trait collection; AppKit has no per-color equivalent, so the
    /// conversion runs with the aqua appearance made current, which is what a dynamic `NSColor` consults.
    ///
    /// Returns `nil` when the color has no RGB representation (a pattern color), leaving the caller to pass the
    /// original through untouched — the same fallback the iOS-only version took when `getRed` reported failure.
    private static func lightAppearanceRGBA(
        of color: PlatformColor,
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        #if canImport(UIKit)
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (r, g, b, a)
        #else
        var resolved: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let resolved else { return nil }
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
        #endif
    }

    /// The median of `values`, or `nil` when empty.
    private static func median(of values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

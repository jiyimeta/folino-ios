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

// PARITY(android): erasable ink in exported PDFs — the AKAnnotationV2 payload is a PencilKit drawing archive
//   (`PKDrawing.dataRepresentation()`), which only PencilKit can write. Android has no PDF export to call it
//   from either; it would need both an export path and a writer for PencilKit's archive container.

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
/// approximates rather than reproduces.
///
/// Each annotation also carries Apple's own `/AAPL:AKExtras` → `AAPL:AKAnnotationV2` archive, which is what makes
/// the mark ERASABLE in Apple's markup rather than merely visible. The drawing inside it is the placed stroke's
/// `PKDrawing.dataRepresentation()`, in the archive's canvas space — the same bytes Books writes into that slot,
/// so AnnotationKit re-creates the editable drawing with `PKDrawing(data:)` and nothing about the stroke encoding
/// is synthesized. An earlier revision hand-built the older gzip-wrapped protobuf form from the neutral `InkStroke`
/// and guessed the drawing's bounding box from the point extent; a marker's rendered extent is not that, and the
/// mark landed tens of points off. `PKDrawing.bounds` is what AnnotationKit recomputes, so it is what the archive
/// rectangle and the annotation's `/Rect` derive from. See `docs/engineering/crdt-ink-format/`.
///
/// PencilKit renders a stroke wider or narrower than its point `size` depending on the ink — a pen of size `s`
/// draws `2s − 4` wide in its own units, a marker `s / 2` (`PencilKitInkWidth`). That constant term is why the
/// export re-solves point sizes for the archive's canvas against the reader's on-screen scale (`canvasDrawing`),
/// and the appearance stream's line width follows the same formula so a PDF viewer that draws the vector shows
/// the same thickness Apple's markup does.
///
/// The key is set on each annotation as it is built, and the document is serialized once. An earlier revision
/// attached the payloads on a SECOND pass — serialize, reparse the bytes, match each payload to an annotation by
/// its recorded position in the page's `/Annots` order, serialize again — because the key appeared not to survive
/// `dataRepresentation()` when set on a freshly created annotation. That measurement was an artifact of a broken
/// iOS 27.0 simulator runtime, where `PDFAnnotation.add(_:)` itself fails (`Cannot save value for annotation key:
/// /InkList. Invalid type.`) and the failure cascades into AnnotationKit adopting the annotation and overwriting
/// the key. On a working runtime the value survives byte-for-byte, and one-pass and two-pass output were measured
/// equivalent — same key sets, same `AKExtras` archive bytes, same `/InkList`, same vector `/AP`, pixel-identical
/// rendering. If this symptom ever reappears on some later OS, it is the runtime that wants checking first, not
/// this code.
///
/// Attaching the payload is strictly best-effort: a stroke whose archive cannot be built or set is written
/// exactly as it was before the payload existed — an `/Ink` annotation with folino's own vector appearance — so
/// the worst case is the behavior that already shipped. The count of such strokes travels back out of `compose`
/// so the renderer can log it.
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
    ///   - screenScale: how many page points one of the reader's on-screen document units is worth — the engraving's
    ///     staff size over the on-screen one. PencilKit's stroke width has a constant term in content units
    ///     (`PencilKitInkWidth`), so a stroke the reader drew in document units and the archive draws in canvas
    ///     units come out different widths unless the point sizes are re-solved for the canvas; this is the scale
    ///     that re-solving needs. `nil` writes the sizes unscaled, and the mark renders as PencilKit would draw it
    ///     at page scale.
    /// - Returns: the composed document's bytes, and how many of the stamped annotations went out without an
    ///   `AKAnnotationV2` payload. The composer is a stateless `enum` with no analytics of its own, so the count
    ///   travels back to `ReaderAnnotatedPDFRenderer` — which holds one — rather than the composer reaching
    ///   sideways for a dependency.
    /// - Throws: `DomainError.scoreWriteFailed` when `basePDF` cannot be read as a PDF, or when the composed
    ///   document cannot be re-serialized.
    static func compose(
        basePDF: Data,
        drawings: [DrawingAnchor],
        placements: [InkPlacement],
        screenScale: CGFloat? = nil,
    ) throws -> (data: Data, akEncodeFailures: Int) {
        guard let document = PDFDocument(data: basePDF) else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: base PDF is unreadable")
        }

        var akEncodeFailures = 0
        for placement in placements {
            guard placement.pageIndex >= 0, placement.pageIndex < document.pageCount,
                  let page = document.page(at: placement.pageIndex),
                  let composed = makeAnnotation(
                      for: placement, drawings: drawings, page: page, screenScale: screenScale,
                  )
            else { continue }
            if !composed.hasAKPayload {
                akEncodeFailures += 1
            }
            page.addAnnotation(composed.annotation)
        }

        guard let data = document.dataRepresentation() else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: could not serialize the composed PDF")
        }
        return (data, akEncodeFailures)
    }

    /// One stamped annotation, and whether Apple's editable payload could be built and set on it. A placement
    /// that produces no annotation at all is not counted as a payload failure — nothing was exported for it to
    /// be missing from.
    private struct ComposedAnnotation {
        let annotation: PDFAnnotation
        let hasAKPayload: Bool
    }

    /// Decodes the placed drawing, bakes the placement's transform into its points (page-local, top-left origin,
    /// y-down — see `InkStrokePencilKitBridge.bakingTransformIntoPoints`), and builds one `.ink` annotation from the
    /// result. Also encodes and attaches Apple's `AKAnnotationV2` payload to that same annotation before returning
    /// it, so the whole annotation — vector appearance and editable payload alike — is produced in one pass. `nil`
    /// when the drawing index is out of range, the stored bytes don't decode, or the placed geometry collapses to
    /// nothing (clipped fully off the page).
    private static func makeAnnotation(
        for placement: InkPlacement, drawings: [DrawingAnchor], page: PDFPage, screenScale: CGFloat?,
    ) -> ComposedAnnotation? {
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

        // The same drawing in the archive's canvas space. Its `bounds` are the one box the archive rectangle and the
        // annotation's /Rect derive from: AnnotationKit recomputes the same bounds from the same drawing and places
        // the mark by them, so any other box moves the ink. Note the rectangle is deliberately NOT clipped to the
        // page — an intersection would move it out from under the drawing. The page height read here is the REAL
        // media box, never a nominal paper size — folino's own exports measure 595.4458 x 841.6944, and A4's
        // nominal 841.8898 against that is already enough drift to lose the annotation.
        let canvasDrawing = canvasDrawing(of: placed, screenScale: screenScale)
        let canvasBounds = canvasDrawing.bounds
        guard !canvasBounds.isNull, !canvasBounds.isEmpty else { return nil }

        let archiveRect = AKInkGeometry.archiveRect(canvasBounds: canvasBounds, pageHeight: pageSize.height)
        guard archiveRect.intersects(CGRect(origin: .zero, size: pageSize)) else { return nil }
        let annotationBounds = AKInkGeometry.annotationRect(archiveRect)

        // `PDFAnnotation.border.lineWidth` is a single width for the whole stroke; the median point size (not the
        // mean) is the more faithful representative for a tapered stroke, where a few very thin or very thick
        // samples — the stroke's own start/end, a pressure spike — would otherwise pull a single width away from
        // what most of the stroke actually looks like. The width is what PencilKit will draw for that size in the
        // archive's canvas, scaled onto the page, so the vector and Apple's markup show the same thickness.
        let canvasSizes = canvasDrawing.strokes.flatMap { $0.path.map { CGFloat($0.size.width) } }
        let canvasSize = median(of: canvasSizes) ?? 1
        let lineWidth = max(
            0.25,
            PencilKitInkWidth.renderedWidth(ink: firstStroke.ink.inkType, size: canvasSize) / AKInkGeometry.canvasScale,
        )

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

        // Apple's editable payload goes on the annotation right here, before it is ever added to a page, and the
        // document is serialized once. See the type's own documentation for the two-pass revision this replaced.
        let payload = akPayload(for: canvasDrawing, archiveRect: archiveRect, pageSize: pageSize)
        // `setValue(_:forAnnotationKey:)` returns `false` when PDFKit rejects the value outright (the SDK logs
        // "-[PDFAnnotation setValue:forAnnotationKey:] failed" in that case), so its result — not just whether a
        // payload was built — decides `hasAKPayload`. This is a partial guard, not a regression detector: it would
        // NOT have caught the iOS 27.0 case documented above, where `add(_:)` itself failed and AnnotationKit
        // overwrote the key later at serialization, so `setValue` here still returned `true`. What it closes is the
        // narrower gap between this call and its documented contract — one class of silent failure becomes a
        // counted one, no more.
        let attached = payload.map {
            annotation.setValue(
                ["AAPL:AKAnnotationV2": $0.base64EncodedString()],
                forAnnotationKey: PDFAnnotationKey(rawValue: "AAPL:AKExtras"),
            )
        } ?? false
        return ComposedAnnotation(annotation: annotation, hasAKPayload: attached)
    }

    /// The Apple ink payload for one placed drawing, or nil if the archive cannot be built.
    ///
    /// Failure here must never fail an export. A stroke without a payload is written exactly as it was before this
    /// existed — an `/Ink` annotation with a vector appearance — so the worst case is the behavior that shipped.
    ///
    /// The drawing's identifiers are PencilKit's own, freshly generated for every drawing it archives, so no two
    /// annotations can share them. That matters: AnnotationKit names a drawing by the identifiers inside its
    /// payload rather than by the annotation holding it, and two annotations sharing them are one drawing — an
    /// eraser stroke on one deletes the other, on whatever page it happens to be.
    private static func akPayload(for canvasDrawing: PKDrawing, archiveRect: CGRect, pageSize: CGSize) -> Data? {
        try? AKInkArchive.archive(
            drawing: canvasDrawing.dataRepresentation(), archiveRect: archiveRect,
            drawingSize: AKInkGeometry.drawingSize(pageSize: pageSize), uuid: UUID(),
        )
    }

    /// The placed drawing in the archive's canvas space: page points times the canvas scale, transform baked in.
    ///
    /// Point sizes are not simply scaled along. PencilKit's rendered width has a constant term in content units
    /// (`PencilKitInkWidth`), so a size that drew a certain width in the reader's document units draws a different
    /// width in canvas units. With `screenScale` (page points per document unit) known, each point's size is
    /// re-solved: the width the reader showed, in page points, is what the size must render to in the canvas —
    /// `renderedWidth` in document units, converted, then `size(forRenderedWidth:)` in canvas units. Without it the
    /// sizes scale with the geometry and the width comes out as PencilKit would draw the stroke at page scale.
    static func canvasDrawing(of placed: PKDrawing, screenScale: CGFloat?) -> PKDrawing {
        let k = AKInkGeometry.canvasScale
        return PKDrawing(strokes: placed.strokes.map { stroke in
            let ink = stroke.ink.inkType
            let points = stroke.path.map { p in
                let canvasSize: CGSize
                if let r = screenScale, r > 0 {
                    let onScreen = PencilKitInkWidth.renderedWidth(ink: ink, size: p.size.width / r) * r
                    let width = PencilKitInkWidth.size(forRenderedWidth: onScreen * k, ink: ink)
                    let aspect = p.size.width > 0 ? p.size.height / p.size.width : 1
                    canvasSize = CGSize(width: width, height: width * aspect)
                } else {
                    canvasSize = CGSize(width: p.size.width * k, height: p.size.height * k)
                }
                return PKStrokePoint(
                    location: CGPoint(x: p.location.x * k, y: p.location.y * k),
                    timeOffset: p.timeOffset, size: canvasSize,
                    opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude,
                )
            }
            return PKStroke(
                ink: stroke.ink,
                path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                transform: .identity,
                mask: stroke.mask.map { mask in
                    var scale = CGAffineTransform(scaleX: k, y: k)
                    let path = mask.cgPath.copy(using: &scale) ?? mask.cgPath
                    return PlatformBezierPath(cgPath: path)
                },
            )
        })
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

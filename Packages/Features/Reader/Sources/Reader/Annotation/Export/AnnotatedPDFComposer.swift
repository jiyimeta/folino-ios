import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
import ReaderAnnotationCore
import UIKit

/// Stamps annotation ink onto a base PDF's pages as PDF annotations and returns the new document's bytes.
///
/// Each annotated page gains exactly ONE `PDFAnnotation`, holding every stroke placed on that page — the same
/// one-annotation-per-page model Apple Books uses (its Pencil markup writes a single `/Stamp` per page whose
/// payload is a whole-page drawing of tens of kilobytes, not one annotation per stroke). The base document's own
/// pages, sizes, content streams and existing annotations are never touched — nothing rewrites the page body. That
/// is what makes the ink erasable as a first-class PDF object in any PDF editor, on any device, rather than a
/// raster the app itself baked into the page; erasing a single mark within a page is then PencilKit's job, on the
/// drawing it reconstructs from the private payload below.
///
/// The appearance is drawn as vector, from each placed stroke's own per-point geometry — a `UIBezierPath` built by
/// walking the decoded (and placed) `PKStroke`'s points — rather than by rasterizing through PencilKit.
/// `PKDrawing.image(from:scale:)` proved unusable on device: it returned a fully transparent raster for the user's
/// own strokes, and twelve hypotheses (invocation style, every tool, color, storage format, stroke mask, point
/// count, timestamp collisions) were each falsified without finding the cause. Walking `PKStroke.path` and
/// `PKDrawing.transform(using:)` — the same geometry APIs the on-screen ink layer already relies on — is a
/// different, deterministic code path with no rasterizer involved, so it sidesteps the bug rather than working
/// around it. The visible cost is pressure taper and marker blending, which a single-width vector stroke
/// approximates rather than reproduces; monoline (a constant-width tool) is exact.
///
/// Consolidating a page into ONE annotation costs the appearance its per-stroke color and width, because
/// `PDFAnnotation` carries a single `/C` and a single border width — see `dominantColor(of:)`. Nothing is lost from
/// the `/PPK` payload, which keeps every stroke exactly as drawn; the cost is only to what a non-PencilKit viewer
/// renders, and only on a page whose strokes disagree.
///
/// The written annotation is shaped like the ones Apple Books writes for Pencil markup, measured field by field from
/// a Books-exported PDF: subtype `/Stamp` (Books reserves `/Square` for shape markup), a `/AAPL:AKExtras`
/// DICTIONARY carrying `/PPK` (base64 of the page drawing's `PKDrawing.dataRepresentation()`) and `/PPKType` (base64 of
/// the constant three bytes `76 b6 b0` — which spells "draw"), `/F = 644` (Print + Locked + LockedContents, so
/// generic PDF editors leave the annotation alone and the private payload stays the editable truth), and
/// `/T = "Mobile User"`. Matching that shape is what gives Apple's own markup tools a chance to reconstruct
/// folino's ink as an editable PencilKit drawing rather than treating it as a foreign annotation. Whether they
/// actually do is undocumented and unverifiable from here — a reader that ignores the private keys loses nothing,
/// since the annotation still draws from `/AP` and still deletes as a normal PDF object.
///
/// One field could NOT be reproduced. Books' `/PPK` decodes to a container beginning `crdt`; every public PencilKit
/// route measured on the iOS 26 simulator — `PKDrawing(strokes:)`, `appending(_:)`, `transform(using:)`, a
/// round trip through `PKDrawing(data:)`, assignment through a `PKCanvasView`, and every `PKInkingTool.InkType`
/// across content versions 1 through 3 — emits the `wrd`-prefixed container instead, with only the version byte
/// changing. `crdt` is PencilKit's newer private document container and `dataRepresentation()` does not produce it.
/// `PKDrawing(data:)` reads both, so a PencilKit-aware reader is unaffected; nothing here can synthesize Apple's
/// variant.
///
/// The Books shape is applied in a SECOND serialization pass, and that ordering is load-bearing rather than
/// incidental. PDFKit generates an annotation's appearance stream from its subtype: an `/Ink` annotation's `/AP` is
/// built from the paths handed to `add(_:)` (`0 0 m 60 20 l S` — real vector), while a `/Stamp` annotation ignores
/// those paths entirely and gets a default box-and-cross appearance instead. So pass one writes `/Ink` annotations
/// to earn the vector appearance, and pass two reopens the finished document and rewrites `/Subtype` on the parsed
/// annotations — at which point the already-written `/AP` is preserved verbatim (measured) and PDFKit drops the now
/// meaningless `/InkList`, exactly as Books' own stamps have none.
@MainActor
enum AnnotatedPDFComposer {
    /// Apple's private annotation key, whose value is a dictionary — NOT a bare string. PDFKit does serialize a
    /// nested `NSDictionary` under a custom annotation key; this was measured by reading the composed file back
    /// through `CGPDFDictionary`, which reports `/AAPL:AKExtras` as a dictionary object with both entries intact.
    static let appleExtrasAnnotationKey = PDFAnnotationKey(rawValue: "AAPL:AKExtras")

    /// The key, inside `/AAPL:AKExtras`, holding base64 of `PKDrawing.dataRepresentation()`.
    static let pencilKitBlobKey = "PPK"

    /// The key, inside `/AAPL:AKExtras`, holding base64 of `pencilKitBlobTypeBytes`.
    static let pencilKitBlobTypeKey = "PPKType"

    /// The three bytes Books stores (base64-encoded) under `/PPKType`. Identical across every annotation in the
    /// dissected file, so it reads as a constant tag rather than per-stroke data — and its base64 is the ASCII
    /// string "draw", which is a strong hint that is exactly what it is.
    static let pencilKitBlobTypeBytes = Data([0x76, 0xB6, 0xB0])

    /// `/F`: Print (4) + Locked (128) + LockedContents (512). Books locks its markup so generic PDF editors don't
    /// mutate an annotation whose editable truth lives in the private payload.
    static let annotationFlags = 644

    /// `/T`. Books writes this for Pencil markup made on iOS; PDFKit's own default is an empty string.
    static let annotationAuthor = "Mobile User"

    /// A private key used ONLY between the two serialization passes, to carry each annotation's PencilKit blob and
    /// to identify precisely the annotations this composer added. It is removed in pass two, so it never reaches a
    /// written file — which also means a base document that is itself a folino export can never be mistaken for
    /// pass-one output and rewritten. `/NM`, the standard candidate for such a marker, is not an option: PDFKit
    /// silently drops it (measured — it reads back `nil` after a round trip).
    private static let stagingBlobAnnotationKey = PDFAnnotationKey(rawValue: "FolinoExportPPK")

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

        var byPage: [Int: [InkPlacement]] = [:]
        for placement in placements
            where placement.pageIndex >= 0 && placement.pageIndex < document.pageCount
        {
            byPage[placement.pageIndex, default: []].append(placement)
        }

        var added = 0
        for pageIndex in byPage.keys.sorted() {
            guard let page = document.page(at: pageIndex), let onThisPage = byPage[pageIndex],
                  let annotation = makeAnnotation(for: onThisPage, drawings: drawings, page: page)
            else { continue }
            page.addAnnotation(annotation)
            added += 1
        }

        guard let data = document.dataRepresentation() else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: could not serialize the composed PDF")
        }
        guard added > 0 else { return data }
        return try applyingBooksShape(to: data)
    }

    /// Pass two: reopen the pass-one document and rewrite every annotation this composer added into the shape Apple
    /// Books writes — see the type's own documentation for why the subtype flip has to happen here rather than at
    /// construction time. Annotations without the staging key (the base document's own) are not touched.
    private static func applyingBooksShape(to data: Data) throws -> Data {
        guard let document = PDFDocument(data: data) else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: the composed PDF could not be reopened")
        }
        let blobType = pencilKitBlobTypeBytes.base64EncodedString()
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let blob = annotation.value(forAnnotationKey: stagingBlobAnnotationKey) as? String
                else { continue }
                annotation.removeValue(forAnnotationKey: stagingBlobAnnotationKey)
                annotation.setValue("Stamp", forAnnotationKey: .subtype)
                annotation.setValue(
                    [pencilKitBlobKey: blob, pencilKitBlobTypeKey: blobType] as NSDictionary,
                    forAnnotationKey: appleExtrasAnnotationKey,
                )
                annotation.setValue(NSNumber(value: annotationFlags), forAnnotationKey: .flags)
                annotation.setValue(annotationAuthor, forAnnotationKey: .textLabel)
            }
        }
        guard let reshaped = document.dataRepresentation() else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: could not re-serialize the composed PDF")
        }
        return reshaped
    }

    /// Decodes every placement destined for `page`, bakes each one's transform into its points (page-local,
    /// top-left origin, y-down — see `InkStrokePencilKitBridge.bakingTransformIntoPoints`), and builds ONE
    /// annotation carrying all of them. It is created as `.ink` so that PDFKit generates a vector appearance stream
    /// from the added paths; `applyingBooksShape(to:)` rewrites the subtype afterwards. `nil` when no placement
    /// decodes, or when the placed geometry collapses to nothing (clipped fully off the page).
    private static func makeAnnotation(
        for placements: [InkPlacement], drawings: [DrawingAnchor], page: PDFPage,
    ) -> PDFAnnotation? {
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
        guard let firstStroke = strokes.first else { return nil }
        let placed = PKDrawing(strokes: strokes)

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

        // `PDFAnnotation.border.lineWidth` is a single width for the WHOLE annotation, and there is now one
        // annotation per page, so this is one width for every stroke on the page. The median across every point
        // (not the mean) is the more faithful representative for tapered strokes, where a few very thin or very
        // thick samples — a stroke's own start/end, a pressure spike — would otherwise pull a single width away
        // from what most of the ink actually looks like.
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
            let path = UIBezierPath()
            path.move(to: annotationPoint(first.location))
            for point in points.dropFirst() {
                path.addLine(to: annotationPoint(point.location))
            }
            annotation.add(path)
        }
        annotation.color = dominantColor(of: placed.strokes) ?? color(of: firstStroke)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        // Staged, not final: `applyingBooksShape(to:)` moves this into `/AAPL:AKExtras` and drops the staging key.
        annotation.setValue(
            placed.dataRepresentation().base64EncodedString(), forAnnotationKey: stagingBlobAnnotationKey,
        )
        return annotation
    }

    /// The annotation's color, folding the stroke's PencilKit opacity — a per-point translucency multiplier
    /// PencilKit applies at render time for tools like the marker, separate from the ink color's own alpha channel —
    /// into the color's alpha, since `PDFAnnotation` has no separate opacity property. Resolved under the light
    /// trait first: stored ink colors are canonical light-appearance sRGB, so a dynamic color inside a legacy
    /// `PKDrawing` archive must not come out dark-adapted on a white page.
    private static func color(of stroke: PKStroke) -> UIColor {
        let resolved = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return resolved }
        let opacity = CGFloat(stroke.path.first?.opacity ?? 1)
        return UIColor(red: r, green: g, blue: b, alpha: a * opacity)
    }

    /// The color the page's annotation is drawn in. `PDFAnnotation` carries ONE color, and there is now one
    /// annotation per page, so a page whose strokes disagree has to settle on a single one for the appearance
    /// stream: the color covering the most sampled points wins, first-seen breaking a tie. A page drawn entirely in
    /// one color — the ordinary case — is therefore exact. This is the visible price of consolidating the page into
    /// a single annotation; the per-stroke colors are all still intact inside the `/PPK` drawing, so a reader that
    /// picks the payload up loses nothing. `nil` when `strokes` is empty.
    private static func dominantColor(of strokes: [PKStroke]) -> UIColor? {
        var buckets: [(key: String, color: UIColor, weight: Int)] = []
        for stroke in strokes {
            let resolved = color(of: stroke)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            let key = [r, g, b, a].map { String(format: "%.3f", $0) }.joined(separator: ",")
            if let index = buckets.firstIndex(where: { $0.key == key }) {
                buckets[index].weight += stroke.path.count
            } else {
                buckets.append((key, resolved, stroke.path.count))
            }
        }
        guard var best = buckets.first else { return nil }
        for bucket in buckets.dropFirst() where bucket.weight > best.weight {
            best = bucket
        }
        return best.color
    }

    /// The median of `values`, or `nil` when empty.
    private static func median(of values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

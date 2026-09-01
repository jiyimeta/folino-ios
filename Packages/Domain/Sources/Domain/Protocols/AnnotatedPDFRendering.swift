import Foundation
import SheetMusicCore

/// Renders a score, or a PDF-origin item's original file, to PDF bytes with the item's freehand annotations baked in.
///
/// Injected the way `ScorePDFRenderer` is, and for the same reason: baking ink needs the engraving layout and a
/// platform ink renderer, and neither may leak into Domain or Infrastructure. The implementation lives in the Reader
/// feature, which already owns anchor projection and the PencilKit bridge.
///
/// Failures throw `DomainError.scoreWriteFailed`.
public protocol AnnotatedPDFRendering: Sendable {
    /// The engraved notation with `drawings`' `.musical` anchors baked in. `.page` anchors are ignored — they belong
    /// to the original PDF. `title` reaches the PDF's metadata.
    func renderAnnotatedEngravedPDF(
        score: Score, title: String, drawings: [DrawingAnchor],
    ) async throws -> Data

    /// `basePDF`'s own pages with `drawings`' `.page` anchors baked in. `.musical` anchors are ignored. The base
    /// document's page count, sizes and vector content are preserved.
    func renderAnnotatedOriginalPDF(basePDF: Data, drawings: [DrawingAnchor]) async throws -> Data
}

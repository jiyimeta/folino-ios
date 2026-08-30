import CoreGraphics
import Foundation
import ReaderAnnotationCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicPDF

/// Reconstructs the layout that `PDFExporter.export` will use, so annotation ink can be placed on the pages the
/// exporter is about to produce.
///
/// swift-sheet-music exposes the pieces for exactly this: `PDFExporter.resolve` is documented "Public so on-screen
/// previewers can mirror the geometry that the exported PDF will have", and `PDFExporter.paginate` "so previewers can
/// mirror the export layout". What is NOT exposed is the three lines between them — the `ScoreViewOptions`, the
/// available width, and the `LayoutEngine.layout` call — so those are mirrored here.
///
/// Mirroring can drift when swift-sheet-music changes. Two things stop that from becoming misplaced ink:
/// `EngravedExportLayoutTests` compares this against a real export, and `ReaderAnnotatedPDFRenderer` re-checks the
/// page count and media box at run time and skips the ink rather than stamp it at coordinates it cannot trust.
@MainActor
enum EngravedExportLayout {
    struct Resolved {
        /// The engraving the export will draw — also the layout musical anchors must resolve against.
        let document: LayoutDocument
        /// One entry per exported page, in page order.
        let pages: [EngravedPagePlacement]
        /// Every page's size in points. Uniform across the document.
        let pageSize: CGSize
    }

    /// The export options this feature uses. `title` reaches the PDF's metadata, not the page chrome.
    static func exportOptions(title: String) -> PDFExporter.Options {
        PDFExporter.Options(title: title)
    }

    /// - Important: mirrors `PDFExporter.export(score:options:)`. Keep the two in step; the test above is what
    ///   notices when they fall out of it.
    static func resolve(score: Score, options: PDFExporter.Options) -> Resolved {
        let resolved = PDFExporter.resolve(options: options, score: score)
        let layoutOptions = ScoreViewOptions(
            staffSize: resolved.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true,
            breakPolicy: options.breakPolicy,
            showsInvisibleElements: false,
        )
        let availableWidth = max(
            resolved.staffSize * 4,
            resolved.page.size.width
                - resolved.page.oddMargins.leading
                - resolved.page.oddMargins.trailing,
        )
        let document = LayoutEngine.layout(
            score: score, options: layoutOptions, availableWidth: availableWidth,
        )
        let batches = PDFExporter.paginate(
            systems: document.systems, page: resolved.page, policy: options.breakPolicy,
        )
        let pages = batches.enumerated().map { index, batch -> EngravedPagePlacement in
            let margins = resolved.page.margins(forPageIndex: index)
            let marginHeight = max(1, resolved.page.size.height - margins.top - margins.bottom)
            // A page's margin-derived height is an upper bound on what it owns, not the actual answer: pagination
            // breaks a page as soon as one more system would not fit, so a page's real content routinely stops
            // short of that height, and the next page's first system starts inside the leftover span. Left
            // unclamped, that span would satisfy both this page's band and the next page's, and `firstIndex(where:)`
            // (`AnnotatedExportPlanner.planEngraved`) would attribute ink from the top of the next page back onto
            // this one. Clamping to the next page's `startY` makes bands touch (or, if content is sparser than the
            // margins allow, fall short) but never overlap.
            let usableHeight = index + 1 < batches.count
                ? max(1, min(marginHeight, batches[index + 1].startY - batch.startY))
                : marginHeight
            return EngravedPagePlacement(
                startY: batch.startY,
                usableHeight: usableHeight,
                offsetX: margins.leading,
                // The exact translation `PDFPageView` applies to its `Canvas`.
                offsetY: margins.top - batch.startY,
            )
        }
        return Resolved(document: document, pages: pages, pageSize: resolved.page.size)
    }
}

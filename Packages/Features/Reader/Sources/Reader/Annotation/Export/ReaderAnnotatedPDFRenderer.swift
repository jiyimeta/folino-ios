import CoreGraphics
import Domain
import Foundation
import ReaderAnnotationCore
import SheetMusicCore
import UtilityCore

/// `AnnotatedPDFRendering` for iOS. Composes the three halves of the feature: `EngravedExportLayout` reconstructs the
/// pages the exporter will produce, `AnnotatedExportPlanner` decides which stored drawing lands where, and
/// `AnnotatedPDFComposer` stamps them onto the base document.
///
/// Lives in the Reader feature because projecting a musical anchor needs the engraving layout and rasterizing ink
/// needs PencilKit, both of which already live here. Infrastructure reaches it through the Domain protocol only.
public struct ReaderAnnotatedPDFRenderer: AnnotatedPDFRendering {
    private let pdfRenderer: any ScorePDFRenderer
    private let analytics: any Analytics

    /// - Parameters:
    ///   - pdfRenderer: the plain engraving-to-PDF path — the same renderer the unannotated `.pdf` share uses, so
    ///     the annotated export's pages are the pages the plain export would have produced.
    ///   - analytics: where `annotated_export_drifted` is logged when `driftReason` trips. Defaults to a no-op so
    ///     tests and other callers that don't care about the signal need not supply one.
    public init(pdfRenderer: any ScorePDFRenderer, analytics: any Analytics = NoopAnalytics()) {
        self.pdfRenderer = pdfRenderer
        self.analytics = analytics
    }

    public func renderAnnotatedEngravedPDF(
        score: Score, title: String, drawings: [DrawingAnchor],
    ) async throws -> Data {
        let basePDF = try await pdfRenderer.renderPDF(score: score, title: title)
        let placements = await MainActor.run { () -> [InkPlacement] in
            let layout = EngravedExportLayout.resolve(
                score: score, options: EngravedExportLayout.exportOptions(title: title),
            )
            if let reason = driftReason(basePDF: basePDF, layout: layout) {
                analytics.log(.annotatedExportDrifted(reason: reason))
                return []
            }
            return AnnotatedExportPlanner.planEngraved(
                drawings: drawings,
                resolver: LayoutDocumentAnchorResolver(document: layout.document),
                pages: layout.pages,
            )
        }
        guard !placements.isEmpty else { return basePDF }
        return try await MainActor.run {
            try AnnotatedPDFComposer.compose(
                basePDF: basePDF, drawings: drawings, placements: placements,
            )
        }
    }

    public func renderAnnotatedOriginalPDF(basePDF: Data, drawings: [DrawingAnchor]) async throws -> Data {
        guard let provider = CGDataProvider(data: basePDF as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0
        else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: original PDF is unreadable")
        }
        let frames = (1 ... document.numberOfPages).map { number -> CGRect in
            guard let page = document.page(at: number) else { return .zero }
            // Page-local: the planner's output is stamped in each page's own space, so the origin is dropped.
            return CGRect(origin: .zero, size: page.getBoxRect(.mediaBox).size)
        }
        let placements = AnnotatedExportPlanner.planPaged(drawings: drawings, pageFrames: frames)
        guard !placements.isEmpty else { return basePDF }
        return try await MainActor.run {
            try AnnotatedPDFComposer.compose(
                basePDF: basePDF, drawings: drawings, placements: placements,
            )
        }
    }

    /// The drift guard. `EngravedExportLayout` mirrors five lines of `PDFExporter.export`; if a swift-sheet-music
    /// change moved the pagination, the page count or a page's size stops matching and the ink would land on the
    /// wrong page or the wrong spot. A non-`nil` result ships the plain engraving instead of stamping — a share
    /// that is not annotated is a far better failure than one annotated in the wrong place — and is also the
    /// `"reason"` logged on `annotated_export_drifted`.
    ///
    /// Every page's media box is checked, not just the first: a page-1-only check would miss a layout where an
    /// interior page shifted width while page 1 and the overall page count happened to still agree.
    ///
    /// This cannot catch a swift-sheet-music change that reflows systems *within* an unchanged page count and page
    /// size (e.g. a shift in `availableWidth`) — that gap is a spec-level limitation, recorded there rather than
    /// solved here.
    private func driftReason(basePDF: Data, layout: EngravedExportLayout.Resolved) -> String? {
        guard let provider = CGDataProvider(data: basePDF as CFData), let document = CGPDFDocument(provider) else {
            return "unreadable_base_pdf"
        }
        guard document.numberOfPages == layout.pages.count, document.numberOfPages > 0 else {
            return "page_count"
        }
        for pageNumber in 1 ... document.numberOfPages {
            guard let page = document.page(at: pageNumber) else { return "page_count" }
            let box = page.getBoxRect(.mediaBox)
            guard abs(box.width - layout.pageSize.width) < 1, abs(box.height - layout.pageSize.height) < 1 else {
                return "page_size"
            }
        }
        return nil
    }
}

import CoreGraphics
import Domain
import Foundation
import ReaderAnnotationCore
import SheetMusicCore

/// `AnnotatedPDFRendering` for iOS. Composes the three halves of the feature: `EngravedExportLayout` reconstructs the
/// pages the exporter will produce, `AnnotatedExportPlanner` decides which stored drawing lands where, and
/// `AnnotatedPDFComposer` stamps them onto the base document.
///
/// Lives in the Reader feature because projecting a musical anchor needs the engraving layout and rasterizing ink
/// needs PencilKit, both of which already live here. Infrastructure reaches it through the Domain protocol only.
public struct ReaderAnnotatedPDFRenderer: AnnotatedPDFRendering {
    private let pdfRenderer: any ScorePDFRenderer

    /// - Parameter pdfRenderer: the plain engraving-to-PDF path — the same renderer the unannotated `.pdf` share
    ///   uses, so the annotated export's pages are the pages the plain export would have produced.
    public init(pdfRenderer: any ScorePDFRenderer) {
        self.pdfRenderer = pdfRenderer
    }

    public func renderAnnotatedEngravedPDF(
        score: Score, title: String, drawings: [DrawingAnchor],
    ) async throws -> Data {
        let basePDF = try await pdfRenderer.renderPDF(score: score, title: title)
        let placements = await MainActor.run { () -> [InkPlacement] in
            let layout = EngravedExportLayout.resolve(
                score: score, options: EngravedExportLayout.exportOptions(title: title),
            )
            guard agrees(basePDF: basePDF, layout: layout) else { return [] }
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
    /// change moved the pagination, the page count or the page size stops matching and the ink would land on the
    /// wrong page or the wrong spot. Returning `false` here ships the plain engraving instead — a share that is not
    /// annotated is a far better failure than one annotated in the wrong place.
    private func agrees(basePDF: Data, layout: EngravedExportLayout.Resolved) -> Bool {
        guard let provider = CGDataProvider(data: basePDF as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages == layout.pages.count,
              let first = document.page(at: 1)
        else { return false }
        let box = first.getBoxRect(.mediaBox)
        return abs(box.width - layout.pageSize.width) < 1 && abs(box.height - layout.pageSize.height) < 1
    }
}

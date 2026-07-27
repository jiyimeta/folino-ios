@testable import Domain
import Testing

/// Covers the PDF-titling rule shared by the iOS importer (`LiveScoreFileImporter`, via
/// `ScoreFileGateway.pdfSummary`'s `summary.title`) and the Android PDF import path
/// (`LibraryAndroidStore.importScore`, via `PDFImporter.summaryUsingSwiftReader`'s `PDFDocumentSummary.title`).
/// Neither platform keeps its own copy of "prefer the document `/Title`, else the filename".
struct ScorePresentationPDFTests {
    @Test func `document title wins over the filename when present`() {
        let title = ScorePresentation.title(fromFilename: "My Recital.pdf", pdfTitle: "Sample Title")
        #expect(title == "Sample Title")
    }

    @Test func `falls back to the filename-derived title when there is no document title`() {
        let title = ScorePresentation.title(fromFilename: "My Recital.pdf", pdfTitle: nil)
        #expect(title == "My Recital")
    }

    @Test func `an empty document title is treated as absent`() {
        let title = ScorePresentation.title(fromFilename: "My Recital.pdf", pdfTitle: "")
        #expect(title == "My Recital")
    }

    @Test func `displayFields carries the title rule and leaves subtitle-composer nil`() {
        let fields = ScorePresentation.displayFields(sourceFilename: "My Recital.pdf", pdfTitle: "Sample Title")
        #expect(fields == ScoreDisplayFields(title: "Sample Title", subtitle: nil, composer: nil))
    }
}

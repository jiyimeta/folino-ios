@testable import Domain
import Foundation
import Testing

struct ScoreItemPDFConversionTests {
    private func pdfItem() -> ScoreItem {
        ScoreItem(
            title: "The name the user gave it",
            composer: "old composer",
            instrumentationSummary: "",
            localFileName: "score.pdf",
            contentHash: "pdf-hash",
            sizeBytes: 9,
            lengthBeats: 0,
            defaultTempoBpm: 0,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: true,
        )
    }

    private func facts() -> PDFConversionFacts {
        PDFConversionFacts(
            fileName: "score.mscz",
            contentHash: "mscz-hash",
            sizeBytes: 42,
            summary: ScoreFileSummary(
                title: "Title baked in by the exporter",
                composer: "parsed composer",
                instrumentationSummary: "Piano",
                lengthBeats: 64,
                defaultTempoBpm: 96,
                primaryKey: "C",
            ),
        )
    }

    @Test func `adopting a conversion takes content from the parse and labels from the user`() {
        let converted = pdfItem().adoptingPDFConversion(
            facts(),
            sourcePDFFileName: "score.pdf",
            sourcePDFContentHash: "pdf-hash",
        )

        #expect(converted.localFileName == "score.mscz")
        #expect(converted.contentHash == "mscz-hash")
        #expect(converted.sizeBytes == 42)
        #expect(converted.lengthBeats == 64)
        #expect(converted.defaultTempoBpm == 96)
        #expect(converted.composer == "parsed composer")
        #expect(converted.pdfOriginState == .converted)
        #expect(!converted.isPDFDerivedScoreEdited)
        // The user's own labels are untouched — notably the title, which the exporter's baked-in one must not win.
        #expect(converted.title == "The name the user gave it")
        #expect(converted.isFavorite)
    }

    @Test func `marking a failure keeps the item a PDF and remembers not to retry`() {
        let failed = pdfItem().markingPDFConversionFailed(
            sourcePDFFileName: "score.pdf",
            sourcePDFContentHash: "pdf-hash",
        )

        #expect(failed.localFileName == "score.pdf")
        #expect(failed.contentHash == "pdf-hash")
        #expect(failed.pdfConversionFailed)
        #expect(failed.pdfOriginState == .unconverted)
    }
}

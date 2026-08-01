import Domain
import Foundation
import Testing

@Suite("PDFOriginState")
struct PDFOriginStateTests {
    private func item(
        localFileName: String,
        sourcePDFFileName: String? = nil,
        pdfDerivedContentHash: String? = nil,
        contentHash: String = "hash",
    ) -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: 1,
            lengthBeats: 0,
            defaultTempoBpm: 0,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            sourcePDFFileName: sourcePDFFileName,
            pdfDerivedContentHash: pdfDerivedContentHash,
        )
    }

    @Test
    func `an item with no PDF origin is notPDF`() {
        #expect(item(localFileName: "a.mscz").pdfOriginState == .notPDF)
    }

    @Test
    func `a PDF-origin item still stored as a PDF is unconverted`() {
        let subject = item(localFileName: "a.pdf", sourcePDFFileName: "a.pdf")
        #expect(subject.pdfOriginState == .unconverted)
    }

    @Test
    func `a PDF-origin item with a derived hash and a score file is converted`() {
        let subject = item(
            localFileName: "a.mscz",
            sourcePDFFileName: "a.pdf",
            pdfDerivedContentHash: "derived",
        )
        #expect(subject.pdfOriginState == .converted)
    }

    @Test
    func `a derived hash without a score file is still unconverted`() {
        let subject = item(
            localFileName: "a.pdf",
            sourcePDFFileName: "a.pdf",
            pdfDerivedContentHash: "derived",
        )
        #expect(subject.pdfOriginState == .unconverted)
    }

    @Test
    func `defaults keep every pre-existing construction site on notPDF`() {
        let subject = item(localFileName: "a.mscz")
        #expect(subject.sourcePDFFileName == nil)
        #expect(subject.sourcePDFContentHash == nil)
        #expect(subject.pdfDerivedContentHash == nil)
        #expect(subject.pdfConversionFailed == false)
    }

    @Test
    func `the score counts as edited only once its bytes differ from what the conversion wrote`() {
        let untouched = item(
            localFileName: "a.mscz",
            sourcePDFFileName: "a.pdf",
            pdfDerivedContentHash: "hash",
            contentHash: "hash",
        )
        #expect(!untouched.isPDFDerivedScoreEdited)

        let edited = item(
            localFileName: "a.mscz",
            sourcePDFFileName: "a.pdf",
            pdfDerivedContentHash: "derived",
            contentHash: "user-edited",
        )
        #expect(edited.isPDFDerivedScoreEdited)

        #expect(!item(localFileName: "a.mscz").isPDFDerivedScoreEdited)
    }
}

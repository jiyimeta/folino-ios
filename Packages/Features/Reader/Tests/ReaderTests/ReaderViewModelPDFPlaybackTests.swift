import CoreGraphics
import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelPDFPlaybackTests {
    private func makeVM(parser: (any PDFPlaybackParser)?) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            scoresDirectory: FileManager.default.temporaryDirectory,
            pdfPlaybackParser: parser,
        )
    }

    private func sampleResult(
        cursorRect: PDFCursorRect? = PDFCursorRect(pageIndex: 0, rect: CGRect(x: 10, y: 20, width: 4, height: 90)),
    ) -> PDFPlaybackParseResult {
        PDFPlaybackParseResult(
            score: Score(division: 480, parts: [], systemMeasures: [], metaTags: [:]),
            geometry: StubPDFPlaybackGeometry(
                pageSizes: [0: CGSize(width: 600, height: 800)],
                cursorRect: cursorRect,
                hitCursor: .beat(measureIndex: 2, tickInMeasure: 0),
            ),
            diagnostics: [],
        )
    }

    @Test func `a successful parse makes the PDF playable and exposes the cursor rect`() async {
        let vm = makeVM(parser: StubPDFPlaybackParser(result: sampleResult()))

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(vm.isPDFPlaybackReady)
        #expect(vm.canPlayNow)
        #expect(vm.playbackScore != nil)
        #expect(vm.pdfPlaybackData?.geometry is StubPDFPlaybackGeometry)
        #expect(
            vm.pdfCursorRect(for: .beat(measureIndex: 0, tickInMeasure: 0))
                == PDFCursorRect(pageIndex: 0, rect: CGRect(x: 10, y: 20, width: 4, height: 90)),
        )
    }

    @Test func `no injected parser leaves the PDF display-only`() async {
        let vm = makeVM(parser: nil)

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(!vm.isPDFPlaybackReady)
        #expect(vm.pdfPlaybackData == nil)
    }

    @Test func `a parse failure leaves the PDF display-only`() async {
        let vm = makeVM(parser: StubPDFPlaybackParser(result: nil))

        await vm.parsePDFForPlayback(url: URL(filePath: "/tmp/whatever.pdf"))

        #expect(!vm.isPDFPlaybackReady)
        #expect(vm.pdfPlaybackData == nil)
    }
}

// MARK: - Stubs

private struct StubPDFPlaybackParser: PDFPlaybackParser {
    /// `nil` makes `parse` throw, standing in for an unreadable / unparseable PDF.
    let result: PDFPlaybackParseResult?

    func parse(pdfURL: URL) throws -> PDFPlaybackParseResult {
        guard let result else {
            throw DomainError.scoreParseFailed(reason: "stub failure")
        }
        return result
    }
}

private struct StubPDFPlaybackGeometry: PDFPlaybackGeometry {
    let pageSizes: [Int: CGSize]
    let cursorRect: PDFCursorRect?
    let hitCursor: ScoreCursor?

    func cursorRect(for _: ScoreCursor, in _: Score) -> PDFCursorRect? {
        cursorRect
    }

    func cursor(at _: CGPoint, pageIndex _: Int) -> ScoreCursor? {
        hitCursor
    }
}

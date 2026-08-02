@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import SheetMusicCore
import SheetMusicPDF
import Testing

/// A `PDFPlaybackParser` that hands back a canned result, so the converter's own behavior is under test rather than
/// swift-sheet-music's OMR.
private struct StubParser: PDFPlaybackParser {
    let result: Result<PDFPlaybackParseResult, any Error>

    func parse(pdfURL _: URL) throws -> PDFPlaybackParseResult {
        try result.get()
    }
}

struct PDFScoreConverterTests {
    /// A real, playable score — the minimal MSCX fixture, which carries actual notes.
    private func playableResult() throws -> PDFPlaybackParseResult {
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        return PDFPlaybackParseResult(
            score: score,
            geometry: SheetMusicPDFPlaybackGeometry(PDFScoreGeometry()),
            diagnostics: [],
        )
    }

    /// A structurally valid but silent parse: no parts, so nothing is playable.
    private func silentResult() -> PDFPlaybackParseResult {
        PDFPlaybackParseResult(
            score: Score(division: 480, parts: [], metaTags: [:]),
            geometry: SheetMusicPDFPlaybackGeometry(PDFScoreGeometry()),
            diagnostics: [],
        )
    }

    @Test func `a playable parse writes the mscz and reports its facts`() async throws {
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let pdfURL = tmp.url.appending(path: "source.pdf")
        try Data().write(to: pdfURL)
        let destination = tmp.url.appending(path: "out.mscz")

        let converter = try PDFScoreConverter(
            parser: StubParser(result: .success(playableResult())),
            gateway: LiveScoreFileGateway(),
        )
        let outcome = await converter.convert(pdfURL: pdfURL, destinationMSCZ: destination)

        let facts = try #require(outcome.facts)
        #expect(facts.fileName == "out.mscz")
        #expect(!facts.contentHash.isEmpty)
        #expect(facts.sizeBytes > 0)
        #expect(facts.summary.lengthBeats > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func `a parse that throws is not readable and writes nothing`() async throws {
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let destination = tmp.url.appending(path: "out.mscz")

        let converter = PDFScoreConverter(
            parser: StubParser(result: .failure(DomainError.scoreParseFailed(reason: "nope"))),
            gateway: LiveScoreFileGateway(),
        )
        let outcome = await converter.convert(
            pdfURL: tmp.url.appending(path: "source.pdf"),
            destinationMSCZ: destination,
        )

        #expect(outcome.facts == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func `a parse with no playable content is not readable`() async throws {
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let destination = tmp.url.appending(path: "out.mscz")

        let converter = PDFScoreConverter(
            parser: StubParser(result: .success(silentResult())),
            gateway: LiveScoreFileGateway(),
        )
        let outcome = await converter.convert(
            pdfURL: tmp.url.appending(path: "source.pdf"),
            destinationMSCZ: destination,
        )

        #expect(outcome.facts == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@testable import Domain
import Testing

struct ScoreFormatPDFTests {
    @Test func `detects PDF extension`() {
        #expect(ScoreFormat.detect(filename: "song.pdf") == .pdf)
        #expect(ScoreFormat.detect(filename: "SONG.PDF") == .pdf)
    }

    @Test func `canonical extension for PDF`() {
        #expect(ScoreFormat.pdf.canonicalExtension == "pdf")
    }

    @Test func `non PDF unaffected`() {
        #expect(ScoreFormat.detect(filename: "a.mscz") == .mscz)
        #expect(ScoreFormat.detect(filename: "a.unknownext") == nil)
    }
}

@testable import Domain
import Testing

struct ScoreShareFormatTests {
    @Test func `canonical extensions`() {
        #expect(ScoreShareFormat.museScoreV4.canonicalExtension == "mscz")
        #expect(ScoreShareFormat.museScoreV3.canonicalExtension == "mscz")
        #expect(ScoreShareFormat.pdf.canonicalExtension == "pdf")
        #expect(ScoreShareFormat.midi.canonicalExtension == "mid")
        #expect(ScoreShareFormat.audioM4A.canonicalExtension == "m4a")
    }

    @Test func `all ordered matches iOS menu order`() {
        #expect(ScoreShareFormat.allOrdered == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
    }

    @Test func `matching maps source to format`() {
        #expect(ScoreShareFormat.matching(for: .midi) == .midi)
        #expect(ScoreShareFormat.matching(for: .museScore(.v4)) == .museScoreV4)
        #expect(ScoreShareFormat.matching(for: .museScore(.v3)) == .museScoreV3)
        #expect(ScoreShareFormat.matching(for: .museScore(.v2)) == nil)
        #expect(ScoreShareFormat.matching(for: .musicXML) == nil)
        #expect(ScoreShareFormat.matching(for: .pdf) == nil)
        #expect(ScoreShareFormat.matching(for: .unknown) == nil)
    }

    @Test func `sanitize replaces hostile chars trims and caps`() {
        #expect(ScoreExportNaming.sanitize(title: "a/b:c\\d") == "a_b_c_d")
        #expect(ScoreExportNaming.sanitize(title: "  __  ") == "score")
        #expect(ScoreExportNaming.sanitize(title: "") == "score")
        #expect(ScoreExportNaming.sanitize(title: String(repeating: "x", count: 200)).count == 100)
        #expect(ScoreExportNaming.sanitize(title: "a\u{0000}b") == "a_b")
        #expect(ScoreExportNaming.sanitize(title: "///") == "score")
    }

    // MARK: - ScoreShareFormatOption.menu

    private static let plainRows: [ScoreShareFormatOption] = ScoreShareFormat.allOrdered.map {
        ScoreShareFormatOption(format: $0, isOriginal: $0 == .museScoreV4)
    }

    @Test func `annotated rows land directly after the plain PDF row, not at the end`() {
        let annotated = [
            ScoreShareFormatOption(format: .annotatedPDF),
            ScoreShareFormatOption(format: .annotatedOriginalPDF),
        ]
        let merged = ScoreShareFormatOption.menu(plain: Self.plainRows, annotated: annotated)
        #expect(merged.map(\.format) == [
            .museScoreV4, .museScoreV3, .pdf, .annotatedPDF, .annotatedOriginalPDF, .midi, .audioM4A,
        ])
    }

    @Test func `no annotated ink leaves the plain rows untouched`() {
        let merged = ScoreShareFormatOption.menu(plain: Self.plainRows, annotated: [])
        #expect(merged == Self.plainRows)
    }

    @Test func `isOriginal on the plain rows survives the merge`() {
        let merged = ScoreShareFormatOption.menu(
            plain: Self.plainRows, annotated: [ScoreShareFormatOption(format: .annotatedPDF)],
        )
        #expect(merged.first { $0.format == .museScoreV4 }?.isOriginal == true)
        #expect(merged.first { $0.format == .museScoreV3 }?.isOriginal == false)
    }

    @Test func `annotated rows are never flagged isOriginal`() {
        let merged = ScoreShareFormatOption.menu(
            plain: Self.plainRows,
            annotated: [
                ScoreShareFormatOption(format: .annotatedPDF),
                ScoreShareFormatOption(format: .annotatedOriginalPDF),
            ],
        )
        #expect(merged.first { $0.format == .annotatedPDF }?.isOriginal == false)
        #expect(merged.first { $0.format == .annotatedOriginalPDF }?.isOriginal == false)
    }

    @Test func `only the engraved annotated row still lands right after PDF`() {
        let merged = ScoreShareFormatOption.menu(
            plain: Self.plainRows, annotated: [ScoreShareFormatOption(format: .annotatedPDF)],
        )
        #expect(merged.map(\.format) == [.museScoreV4, .museScoreV3, .pdf, .annotatedPDF, .midi, .audioM4A])
    }

    @Test func `merging does not mutate allOrdered`() {
        _ = ScoreShareFormatOption.menu(
            plain: Self.plainRows, annotated: [ScoreShareFormatOption(format: .annotatedPDF)],
        )
        #expect(ScoreShareFormat.allOrdered == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
    }
}

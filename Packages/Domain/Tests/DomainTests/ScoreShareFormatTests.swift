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
}

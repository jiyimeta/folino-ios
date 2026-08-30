@testable import Domain
import Testing

@Suite("AnnotatedExportAvailability")
struct AnnotatedExportAvailabilityTests {
    @Test
    func `a score with no ink offers no annotated row`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: false, hasPageInk: false, hasOriginalPDF: false, isEngravable: true,
        ) == [])
    }

    @Test
    func `an ordinary annotated score offers the engraved row only`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: true, hasPageInk: false, hasOriginalPDF: false, isEngravable: true,
        ) == [.annotatedPDF])
    }

    @Test
    func `an unconverted PDF offers the original row and never the engraved one`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: true, hasPageInk: true, hasOriginalPDF: true, isEngravable: false,
        ) == [.annotatedOriginalPDF])
    }

    @Test
    func `page ink without an original PDF on disk offers nothing`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: false, hasPageInk: true, hasOriginalPDF: false, isEngravable: true,
        ) == [])
    }

    @Test
    func `a converted PDF item annotated on both sources offers both rows in order`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: true, hasPageInk: true, hasOriginalPDF: true, isEngravable: true,
        ) == [.annotatedPDF, .annotatedOriginalPDF])
    }

    @Test
    func `a converted PDF item with only page ink offers the original row only`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: false, hasPageInk: true, hasOriginalPDF: true, isEngravable: true,
        ) == [.annotatedOriginalPDF])
    }

    @Test
    func `annotated filenames are suffixed so they cannot collide with the plain PDF`() {
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .pdf) == "Sonata.pdf")
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .annotatedPDF)
            == "Sonata (annotated).pdf")
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .annotatedOriginalPDF)
            == "Sonata (original annotated).pdf")
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .midi) == "Sonata.mid")
    }

    @Test
    func `a hostile title is sanitized before the suffix is appended`() {
        #expect(ScoreExportNaming.fileName(title: "a/b:c", format: .annotatedPDF)
            == "a_b_c (annotated).pdf")
        #expect(ScoreExportNaming.fileName(title: "", format: .annotatedPDF)
            == "score (annotated).pdf")
    }

    @Test
    func `only the annotated formats report isAnnotated`() {
        #expect(ScoreShareFormat.annotatedPDF.isAnnotated)
        #expect(ScoreShareFormat.annotatedOriginalPDF.isAnnotated)
        for format in ScoreShareFormat.allOrdered {
            #expect(!format.isAnnotated)
        }
    }

    @Test
    func `allOrdered stays the five plain formats so bulk share is unaffected`() {
        #expect(ScoreShareFormat.allOrdered == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
    }
}

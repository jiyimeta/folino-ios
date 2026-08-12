@testable import Domain
import Testing

struct PDFReparsePolicyTests {
    @Test func `nothing to lose needs no confirmation`() {
        #expect(!PDFReparsePolicy.needsConfirmation(
            isScoreEdited: false,
            hasScoreBoundPreferences: false,
            hasMusicalAnnotations: false,
        ))
    }

    @Test func `an edited score needs confirmation`() {
        #expect(PDFReparsePolicy.needsConfirmation(
            isScoreEdited: true,
            hasScoreBoundPreferences: false,
            hasMusicalAnnotations: false,
        ))
    }

    @Test func `staff-bound settings alone need confirmation`() {
        #expect(PDFReparsePolicy.needsConfirmation(
            isScoreEdited: false,
            hasScoreBoundPreferences: true,
            hasMusicalAnnotations: false,
        ))
    }

    @Test func `notation-anchored ink alone needs confirmation`() {
        #expect(PDFReparsePolicy.needsConfirmation(
            isScoreEdited: false,
            hasScoreBoundPreferences: false,
            hasMusicalAnnotations: true,
        ))
    }
}

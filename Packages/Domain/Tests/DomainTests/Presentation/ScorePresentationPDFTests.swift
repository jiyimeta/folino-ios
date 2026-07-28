@testable import Domain
import Testing

/// Covers the PDF-titling rule shared by the iOS importer (`LiveScoreFileImporter`) and the Android PDF import
/// path (`LibraryAndroidStore.importScore`). Both go through `ScorePresentation.displayFields(sourceFilename:)`,
/// so neither platform keeps its own copy of the rule — and neither can quietly reinstate the document `/Title`
/// preference this deliberately does NOT have (exporters bake their own project name into `/Title`; the file
/// name is what the user chose).
struct ScorePresentationPDFTests {
    @Test func `the title is the file name, not any document title the PDF carries`() {
        let fields = ScorePresentation.displayFields(sourceFilename: "My Recital.pdf")
        #expect(fields.title == "My Recital")
    }

    @Test func `a PDF gets no subtitle or composer — nothing is decoded at import time`() {
        let fields = ScorePresentation.displayFields(sourceFilename: "My Recital.pdf")
        #expect(fields == ScoreDisplayFields(title: "My Recital", subtitle: nil, composer: nil))
    }

    @Test func `the title matches the non-PDF rule for the same file name`() {
        // Same source name, same title, whatever the format: PDF titling is not a special case.
        #expect(
            ScorePresentation.displayFields(sourceFilename: "My Recital.pdf").title
                == ScorePresentation.title(fromFilename: "My Recital.pdf"),
        )
    }
}

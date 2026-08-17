@testable import Domain
import Foundation
import Testing

@Suite("Revert policy")
struct RevertPolicyTests {
    private func item(
        localFileName: String,
        originalFileName: String?,
        provenance: OriginalProvenance? = .importTime,
    ) -> ScoreItem {
        var item = ScoreItem(
            title: "Kept Title",
            subtitle: "Kept Subtitle",
            composer: "Kept Composer",
            instrumentationSummary: "Kept Instrumentation",
            localFileName: localFileName,
            contentHash: "current",
            sizeBytes: 10,
            lengthBeats: 10,
            defaultTempoBpm: 100,
            primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: true,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = originalFileName == nil ? nil : "orig"
        item.originalProvenance = originalFileName == nil ? nil : provenance
        return item
    }

    private var summary: ScoreFileSummary {
        ScoreFileSummary(
            title: "File Title",
            subtitle: "File Subtitle",
            composer: "File Composer",
            instrumentationSummary: "File Instrumentation",
            lengthBeats: 99,
            defaultTempoBpm: 88,
            primaryKey: "G",
        )
    }

    // MARK: - filePlan

    @Test func `an item with no original has no plan`() {
        #expect(RevertPolicy.filePlan(for: item(localFileName: "ID.mscz", originalFileName: nil)) == nil)
    }

    @Test func `a sidecar is restored over the item's file`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(
            RevertPolicy.filePlan(for: subject)
                == .restoreSidecar(sidecarFileName: "ID.original.mscz", over: "ID.mscz"),
        )
    }

    @Test func `a source file is adopted back and the sibling mscz deleted`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        #expect(
            RevertPolicy.filePlan(for: subject)
                == .adoptExistingFile(originalFileName: "ID.musicxml", deleting: "ID.mscz"),
        )
    }

    // MARK: - warnings

    @Test func `ink anchored to the notation earns a warning`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(
            RevertPolicy.warnings(for: subject, hasMusicalAnnotations: true)
                .contains(.musicalAnnotationsMayShift),
        )
    }

    @Test func `no ink means no shift warning`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(
            RevertPolicy.warnings(for: subject, hasMusicalAnnotations: false)
                .contains(.musicalAnnotationsMayShift) == false,
        )
    }

    @Test func `a legacy original warns that it may not be the import`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz", provenance: .legacyUnknown)
        #expect(
            RevertPolicy.warnings(for: subject, hasMusicalAnnotations: false)
                .contains(.originalMayNotBeImportTime),
        )
    }

    @Test func `a conversion output does not carry the legacy caveat`() {
        let subject = item(
            localFileName: "ID.mscz",
            originalFileName: "ID.original.mscz",
            provenance: .conversionOutput,
        )
        #expect(
            RevertPolicy.warnings(for: subject, hasMusicalAnnotations: false)
                .contains(.originalMayNotBeImportTime) == false,
        )
    }

    // MARK: - adoptingRevertedOriginal

    private var facts: RevertedOriginalFacts {
        RevertedOriginalFacts(
            localFileName: "ID.musicxml",
            contentHash: "orig",
            sizeBytes: 42,
            summary: summary,
        )
    }

    @Test func `content-derived fields always come from the restored file`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: false)
        #expect(reverted.localFileName == "ID.musicxml")
        #expect(reverted.contentHash == "orig")
        #expect(reverted.sizeBytes == 42)
        #expect(reverted.lengthBeats == 99)
        #expect(reverted.defaultTempoBpm == 88)
        #expect(reverted.primaryKey == "G")
        #expect(reverted.instrumentationSummary == "File Instrumentation")
    }

    @Test func `credits are kept unless the caller asks for them`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: false)
        #expect(reverted.title == "Kept Title")
        #expect(reverted.subtitle == "Kept Subtitle")
        #expect(reverted.composer == "Kept Composer")
    }

    @Test func `credits come from the file when asked for`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: true)
        #expect(reverted.title == "File Title")
        #expect(reverted.subtitle == "File Subtitle")
        #expect(reverted.composer == "File Composer")
    }

    @Test func `a file with no title keeps the item's title`() {
        var untitled = facts
        untitled = RevertedOriginalFacts(
            localFileName: facts.localFileName,
            contentHash: facts.contentHash,
            sizeBytes: facts.sizeBytes,
            summary: ScoreFileSummary(
                title: nil,
                composer: nil,
                instrumentationSummary: "x",
                lengthBeats: 1,
                defaultTempoBpm: 1,
                primaryKey: nil,
            ),
        )
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        #expect(subject.adoptingRevertedOriginal(untitled, restoringScoreInfo: true).title == "Kept Title")
    }

    @Test func `the item forgets its original and keeps the user's own labels`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: true)
        #expect(reverted.originalFileName == nil)
        #expect(reverted.originalContentHash == nil)
        #expect(reverted.originalProvenance == nil)
        #expect(reverted.isFavorite)
        #expect(reverted.addedAt == Date(timeIntervalSince1970: 0))
    }

    /// Unlike `rebuilt` (PDF conversion), reverting a MusicXML import back to its own file must land on `nil`, not
    /// keep the version the `.mscz` the editor wrote over it was stamped with. `facts.summary.museScoreMajorVersion`
    /// is `nil` (a MusicXML source), so a stray `?? museScoreMajorVersion` fallback would leak the old `.mscz`
    /// version straight through undetected.
    @Test func `the restored MuseScore version has no fallback to the edited file's version`() {
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        subject.museScoreMajorVersion = 4
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: false)
        #expect(reverted.museScoreMajorVersion == nil)
    }
}

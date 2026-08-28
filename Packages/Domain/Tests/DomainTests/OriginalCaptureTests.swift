@testable import Domain
import Foundation
import Testing

@Suite("Original capture planning")
struct OriginalCaptureTests {
    private func item(
        localFileName: String,
        originalFileName: String? = nil,
        originalProvenance: OriginalProvenance? = nil,
        contentHash: String = "hash-current",
        sourcePDFFileName: String? = nil,
        pdfDerivedContentHash: String? = nil,
    ) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            sourcePDFFileName: sourcePDFFileName,
            pdfDerivedContentHash: pdfDerivedContentHash,
        )
        item.originalFileName = originalFileName
        item.originalProvenance = originalProvenance
        return item
    }

    @Test func `an item that already has an original is not captured again`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(OriginalCapture.plan(for: subject, adoptableSourceFileName: nil) == .none)
    }

    @Test func `an unconverted pdf is never captured`() {
        let subject = item(localFileName: "ID.pdf")
        #expect(OriginalCapture.plan(for: subject, adoptableSourceFileName: nil) == .none)
    }

    @Test func `a musicxml source is adopted where it already sits`() {
        let subject = item(localFileName: "ID.musicxml")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .adopt(fileName: "ID.musicxml", provenance: .importTime),
        )
    }

    @Test func `a midi source is adopted where it already sits`() {
        let subject = item(localFileName: "ID.mid")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .adopt(fileName: "ID.mid", provenance: .importTime),
        )
    }

    @Test func `an orphaned source file beside an mscz is adopted as import-time`() {
        let subject = item(localFileName: "ID.mscz", originalProvenance: .legacyUnknown)
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: "ID.musicxml")
                == .adopt(fileName: "ID.musicxml", provenance: .importTime),
        )
    }

    @Test func `a plain mscz import is copied to a sidecar as import-time`() {
        let subject = item(localFileName: "ID.mscz")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscz", provenance: .importTime),
        )
    }

    @Test func `an mscx import keeps its own extension in the sidecar name`() {
        let subject = item(localFileName: "ID.mscx")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscx", provenance: .importTime),
        )
    }

    @Test func `a converted pdf captures the conversion output`() {
        let subject = item(
            localFileName: "ID.mscz",
            contentHash: "h",
            sourcePDFFileName: "ID.pdf",
            pdfDerivedContentHash: "h",
        )
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscz", provenance: .conversionOutput),
        )
    }

    @Test func `a pre-stamped legacy row keeps its legacy provenance when copied`() {
        let subject = item(localFileName: "ID.mscz", originalProvenance: .legacyUnknown)
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscz", provenance: .legacyUnknown),
        )
    }

    @Test func `adoptable candidates are the non-museScore canonical siblings`() {
        let subject = item(localFileName: "ID.mscz")
        #expect(subject.adoptableSourceFileNames == ["ID.musicxml", "ID.mxl", "ID.mid"])
    }
}

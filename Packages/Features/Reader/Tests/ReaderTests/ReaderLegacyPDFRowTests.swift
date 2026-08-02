import Domain
import Foundation
@testable import Reader
import Testing

/// A PDF imported before the origin columns existed carries no `sourcePDFFileName`. It must still convert on open,
/// still offer the re-read, and still count as PDF-origin — the first cut keyed everything off that column and so did
/// none of it.
@MainActor
struct ReaderLegacyPDFRowTests {
    /// Strips the origin columns the way a row written before migration v15 looks on disk.
    private func legacyRig() throws -> PDFReaderTestRig {
        let rig = try PDFReaderTestRig(conversion: .succeeds)
        rig.stripPDFOriginColumns()
        return rig
    }

    @Test func `a row from before the origin columns still counts as PDF-origin`() throws {
        let rig = try legacyRig()
        #expect(rig.item.sourcePDFFileName == nil)
        #expect(rig.item.pdfOriginState == .unconverted)
    }

    @Test func `a row from before the origin columns converts on open`() async throws {
        let rig = try legacyRig()
        let vm = rig.makeViewModel()

        await vm.load()

        #expect(rig.conversionCallCount == 1)
        #expect(vm.scoreItem.pdfOriginState == .converted)
        #expect(vm.scoreItem.sourcePDFFileName != nil)
        #expect(vm.loadState.score != nil)
    }

    @Test func `a row from before the origin columns offers the re-read`() throws {
        let rig = try legacyRig()
        let vm = rig.makeViewModel()
        #expect(vm.canReReadPDF)
    }
}

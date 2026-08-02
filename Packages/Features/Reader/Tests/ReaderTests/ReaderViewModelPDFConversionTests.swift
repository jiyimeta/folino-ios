import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct ReaderViewModelPDFConversionTests {
    @Test func `opening an unconverted PDF reads it into notation and loads the score`() async throws {
        let rig = try PDFReaderTestRig(conversion: .succeeds)
        let vm = rig.makeViewModel()

        await vm.load()

        #expect(vm.scoreItem.pdfOriginState == .converted)
        #expect(vm.scoreItem.localFileName.hasSuffix(".mscz"))
        #expect(vm.scoreItem.lengthBeats == 32)
        #expect(vm.loadState.score != nil)
        #expect(vm.capabilities == .forScore)
        #expect(rig.repository.savedScoreItems.last?.pdfDerivedContentHash != nil)
    }

    @Test func `a failed conversion falls back to the PDF and is not retried on the next open`() async throws {
        let rig = try PDFReaderTestRig(conversion: .fails)
        let vm = rig.makeViewModel()

        await vm.load()

        #expect(vm.scoreItem.pdfConversionFailed)
        #expect(vm.displaySource == .originalPDF)
        guard case .loadedPDF = vm.loadState else {
            Issue.record("expected .loadedPDF, got \(vm.loadState)")
            return
        }

        let callsAfterFirstOpen = rig.conversionCallCount
        await vm.load()
        #expect(rig.conversionCallCount == callsAfterFirstOpen)
    }

    @Test func `an already-converted item never runs the conversion`() async throws {
        let rig = try PDFReaderTestRig(converted: true)
        let vm = rig.makeViewModel()

        await vm.load()

        #expect(rig.conversionCallCount == 0)
    }

    @Test func `a plain score item never runs the conversion`() async throws {
        let rig = try PDFReaderTestRig.scoreItem()
        let vm = rig.makeViewModel()

        await vm.load()

        #expect(rig.conversionCallCount == 0)
        #expect(vm.scoreItem.pdfOriginState == .notPDF)
    }
}

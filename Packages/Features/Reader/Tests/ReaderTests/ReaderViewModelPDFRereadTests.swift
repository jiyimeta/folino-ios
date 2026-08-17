import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderViewModelPDFRereadTests {
    @Test func `a clean converted item can be re-read without asking`() async throws {
        let vm = try PDFReaderTestRig(converted: true).makeViewModel()
        await vm.load()

        #expect(vm.canReReadPDF)
        #expect(!vm.reReadNeedsConfirmation)
    }

    @Test func `an edited score needs confirmation`() async throws {
        let vm = try PDFReaderTestRig(converted: true, edited: true).makeViewModel()
        await vm.load()

        #expect(vm.reReadNeedsConfirmation)
    }

    @Test func `score-bound settings alone need confirmation`() async throws {
        let vm = try PDFReaderTestRig(converted: true).makeViewModel()
        await vm.load()
        await vm.mutatePreferences { $0.staffClefOverrides = [StaffAddress(partIndex: 0, staffIndexInPart: 0): "F"] }

        #expect(vm.reReadNeedsConfirmation)
    }

    @Test func `a successful re-read rewrites the score and resets score-bound settings`() async throws {
        let rig = try PDFReaderTestRig(converted: true, edited: true)
        let vm = rig.makeViewModel()
        await vm.load()
        await vm.mutatePreferences {
            $0.hiddenStaves = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
            $0.authoredHiddenStaves = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
            $0.transposeSemitones = 3
        }

        await vm.reReadPDF()

        #expect(vm.reReadError == nil)
        #expect(vm.scoreItem.pdfDerivedContentHash == vm.scoreItem.contentHash)
        #expect(!vm.scoreItem.isPDFDerivedScoreEdited)
        #expect(vm.scoreItem.localFileName.hasSuffix(".mscz"))
        #expect(vm.preferences.hiddenStaves.isEmpty)
        // A re-read renumbers the staves, so the old parse's provenance has to go with the hides it described —
        // keeping it beside an emptied `hiddenStaves` would read as "the user revealed all of these".
        #expect(vm.preferences.authoredHiddenStaves.isEmpty)
        #expect(!vm.preferences.hasSeededAuthoredVisibility)
        // Back to untouched, not an explicit 0 — the user's choice no longer applies to the new numbering.
        #expect(vm.preferences.transposeSemitones == nil)
        #expect(vm.displaySource == .score)
    }

    @Test func `a failed re-read changes nothing and reports the error`() async throws {
        let rig = try PDFReaderTestRig(conversion: .fails, converted: true)
        let vm = rig.makeViewModel()
        await vm.load()
        let before = vm.scoreItem

        await vm.reReadPDF()

        #expect(vm.reReadError != nil)
        #expect(vm.scoreItem.contentHash == before.contentHash)
        #expect(vm.scoreItem.localFileName == before.localFileName)
    }

    @Test func `re-reading a PDF folino could not read retries and converts it`() async throws {
        let rig = try PDFReaderTestRig(conversion: .failsThenSucceeds)
        let vm = rig.makeViewModel()
        await vm.load()
        #expect(vm.scoreItem.pdfConversionFailed)

        await vm.reReadPDF()

        #expect(!vm.scoreItem.pdfConversionFailed)
        #expect(vm.scoreItem.pdfOriginState == .converted)
    }

    @Test func `re-reading the pdf forgets the captured original`() async throws {
        let store = FakeScoreOriginalStore()
        let rig = try PDFReaderTestRig(converted: true, originalStore: store)
        let vm = rig.makeViewModel()
        await vm.load()
        var item = vm.scoreItem
        item.originalFileName = "\(item.id.rawValue.uuidString).original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .conversionOutput
        vm.scoreItem = item

        await vm.reReadPDF()

        #expect(store.discardCalls.count == 1)
        #expect(store.discardCalls.first?.originalFileName == "\(item.id.rawValue.uuidString).original.mscz")
        #expect(vm.scoreItem.originalFileName == nil)
    }
}

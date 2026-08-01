import Domain
@testable import Reader
import Testing

@MainActor
struct ReaderDisplaySourceTests {
    @Test func `a converted item can show the original, a plain score cannot`() async throws {
        let converted = try PDFReaderTestRig(converted: true).makeViewModel()
        await converted.load()
        #expect(converted.canShowOriginalPDF)

        let plain = try PDFReaderTestRig.scoreItem().makeViewModel()
        await plain.load()
        #expect(!plain.canShowOriginalPDF)
    }

    @Test func `switching to the original swaps in PDF capabilities and back again`() async throws {
        let vm = try PDFReaderTestRig(converted: true).makeViewModel()
        await vm.load()
        #expect(vm.capabilities == .forScore)

        vm.setDisplaySource(.originalPDF)
        #expect(vm.displaySource == .originalPDF)
        #expect(vm.capabilities == .forPDF)
        #expect(vm.originalPDFDocument != nil)

        vm.setDisplaySource(.score)
        #expect(vm.displaySource == .score)
        #expect(vm.capabilities == .forScore)
    }

    @Test func `an item folino could not read is pinned to the original with no switch`() async throws {
        let vm = try PDFReaderTestRig(conversion: .fails).makeViewModel()
        await vm.load()

        #expect(vm.displaySource == .originalPDF)
        // Nothing to switch to: the notation side doesn't exist.
        #expect(!vm.canShowOriginalPDF)
    }

    @Test func `toggling flips between the two sources`() async throws {
        let vm = try PDFReaderTestRig(converted: true).makeViewModel()
        await vm.load()

        vm.toggleDisplaySource()
        #expect(vm.displaySource == .originalPDF)
        vm.toggleDisplaySource()
        #expect(vm.displaySource == .score)
    }

    @Test func `the original view asks for the on-PDF cursor once per session`() async throws {
        let rig = try PDFReaderTestRig(converted: true)
        let vm = rig.makeViewModel()
        await vm.load()
        #expect(rig.parseCallCount == 0)

        vm.setDisplaySource(.originalPDF)
        try await waitUntil { rig.parseCallCount == 1 }
        #expect(vm.isPDFPlaybackReady)

        vm.setDisplaySource(.score)
        vm.setDisplaySource(.originalPDF)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.parseCallCount == 1)
    }

    @Test func `an edited score gets no on-PDF cursor`() async throws {
        let rig = try PDFReaderTestRig(converted: true, edited: true)
        let vm = rig.makeViewModel()
        await vm.load()

        vm.setDisplaySource(.originalPDF)
        try await Task.sleep(for: .milliseconds(50))

        #expect(rig.parseCallCount == 0)
        #expect(!vm.isPDFPlaybackReady)
    }

    /// Polls until `condition` holds — the cursor parse is kicked off in a detached task, so the switch itself
    /// returns before it lands.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition never became true")
    }
}

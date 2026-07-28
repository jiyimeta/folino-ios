@testable import Domain
import Testing

struct ReaderCapabilitiesTests {
    @Test func `pdf disables everything but page and vertical`() {
        let c = ReaderCapabilities.resolve(format: .pdf)
        #expect(c.canPlay == false)
        #expect(c.canChangeLayout == false)
        #expect(c.canTranspose == false)
        #expect(c.canEditStaves == false)
        #expect(c.availableLayoutModes == [.page, .vertical])
    }

    @Test func `score enables all`() {
        let c = ReaderCapabilities.resolve(format: .mscz)
        #expect(c.canPlay)
        #expect(c.canChangeLayout)
        #expect(c.availableLayoutModes == [.vertical, .horizontal, .page])
    }

    @Test func `pdf becomes playable only when the parse succeeds`() {
        let pdf = ReaderCapabilities.forPDF
        #expect(!ReaderCapabilities.canPlayNow(capabilities: pdf, isPDFPlaybackReady: false))
        #expect(ReaderCapabilities.canPlayNow(capabilities: pdf, isPDFPlaybackReady: true))
    }

    @Test func `scores are playable regardless of pdf readiness`() {
        let score = ReaderCapabilities.forScore
        #expect(ReaderCapabilities.canPlayNow(capabilities: score, isPDFPlaybackReady: false))
    }

    @Test func `pdf offers page and vertical only`() {
        #expect(ReaderCapabilities.forPDF.availableLayoutModes == [.page, .vertical])
    }

    @Test func `zero playable elements is not playable`() {
        #expect(!ReaderCapabilities.isPlayableElementCount(0))
    }

    @Test func `any positive playable element count is playable`() {
        #expect(ReaderCapabilities.isPlayableElementCount(1))
        // 3788 is the measured count for a real MuseScore-CLI PDF export through the Android decode path.
        #expect(ReaderCapabilities.isPlayableElementCount(3788))
    }
}

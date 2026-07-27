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
}

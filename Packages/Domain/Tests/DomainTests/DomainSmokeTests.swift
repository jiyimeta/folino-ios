@testable import Domain
import Testing

struct DomainSmokeTests {
    @Test func `module links`() {
        #expect(DomainModule.isLinked)
    }

    @Test func `sheet music core reexported`() {
        // Verifies the @_exported import surfaces SheetMusicCore through Domain.
        let _: Score.Type = Score.self
    }
}

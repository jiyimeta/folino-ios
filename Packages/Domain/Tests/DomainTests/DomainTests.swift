@testable import Domain
import Testing

@Suite struct DomainSmokeTests {
    @Test func moduleLinks() {
        #expect(DomainModule.isLinked)
    }

    @Test func sheetMusicCoreReexported() {
        // Verifies the @_exported import surfaces SheetMusicCore through Domain.
        let _: Score.Type = Score.self
    }
}

@testable import Reader
import Testing

@Suite struct ReaderSmokeTests {
    @Test func moduleLinks() {
        #expect(ReaderModule.isLinked)
    }
}

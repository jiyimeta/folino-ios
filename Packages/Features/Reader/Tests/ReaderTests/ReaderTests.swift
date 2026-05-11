@testable import Reader
import Testing

struct ReaderSmokeTests {
    @Test func `module links`() {
        #expect(ReaderModule.isLinked)
    }
}

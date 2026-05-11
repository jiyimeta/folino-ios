@testable import Library
import Testing

struct LibrarySmokeTests {
    @Test func `module links`() {
        #expect(LibraryModule.isLinked)
    }
}

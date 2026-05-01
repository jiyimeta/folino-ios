@testable import Library
import Testing

@Suite struct LibrarySmokeTests {
    @Test func moduleLinks() {
        #expect(LibraryModule.isLinked)
    }
}

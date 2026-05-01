@testable import Editor
import Testing

@Suite struct EditorSmokeTests {
    @Test func moduleLinks() {
        #expect(EditorModule.isLinked)
    }
}

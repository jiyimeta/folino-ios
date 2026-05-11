@testable import Editor
import Testing

struct EditorSmokeTests {
    @Test func `module links`() {
        #expect(EditorModule.isLinked)
    }
}

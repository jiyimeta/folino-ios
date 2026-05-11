@testable import ImportExport
import Testing

struct ImportExportSmokeTests {
    @Test func `module links`() {
        #expect(ImportExportModule.isLinked)
    }
}

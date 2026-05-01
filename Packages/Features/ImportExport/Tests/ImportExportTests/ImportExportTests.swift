@testable import ImportExport
import Testing

@Suite struct ImportExportSmokeTests {
    @Test func moduleLinks() {
        #expect(ImportExportModule.isLinked)
    }
}

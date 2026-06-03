import Domain
import Foundation
@testable import SettingsLogic
import Testing

struct YAMLVersionHistoryLoaderTests {
    private let sampleYAML =
        """
        - version: 1.5.1
          descriptions:
            - en: Bug fix
              ja: ja-a
              ko: ko-a
              zh-Hans: ha
              zh-Hant: ht
            - en: Crash fix
              ja: ja-b
        - version: 1.5.0
          descriptions:
            - en: Page view
              ja: ja-c
        """

    @Test func `loads entries from YAML`() throws {
        let entries = try YAMLVersionHistoryLoader(data: Data(sampleYAML.utf8)).load()
        #expect(entries.count == 2)
        #expect(entries[0].version == AppVersion(1, 5, 1))
        #expect(entries[1].version == AppVersion(1, 5, 0))
        #expect(entries[0].descriptions.count == 2)
        #expect(entries[1].descriptions.count == 1)
    }

    @Test func `skips malformed entries and keeps valid ones`() throws {
        let yaml = """
        - version: 1.1.0
          descriptions:
            - en: Good
              ja: 良
        - version: not-a-version
          descriptions: []
        - version: 1.0.0
          descriptions: []
        """
        let entries = try YAMLVersionHistoryLoader(data: Data(yaml.utf8)).load()
        #expect(entries.map(\.version) == [AppVersion(1, 1, 0), AppVersion(1, 0, 0)])
    }

    @Test func `throws when root is not a sequence`() {
        let yaml = "version: 1.0.0\ndescriptions: []"
        #expect(throws: (any Error).self) {
            _ = try YAMLVersionHistoryLoader(data: Data(yaml.utf8)).load()
        }
    }
}

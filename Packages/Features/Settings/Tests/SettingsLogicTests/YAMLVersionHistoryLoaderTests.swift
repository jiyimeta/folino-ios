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
        #expect(throws: YAMLVersionHistoryLoader.LoadError.unparseableRoot) {
            _ = try YAMLVersionHistoryLoader(data: Data(yaml.utf8)).load()
        }
    }

    @Test func `throws on empty document`() {
        #expect(throws: YAMLVersionHistoryLoader.LoadError.unparseableRoot) {
            _ = try YAMLVersionHistoryLoader(data: Data("".utf8)).load()
        }
    }

    @Test func `wire payload round trips`() throws {
        let payload = versionHistoryWirePayload(ymlData: Data(sampleYAML.utf8))
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries.count == 2)
        #expect(list.entries[0].version == "1.5.1")
        #expect(list.entries[1].version == "1.5.0")
        #expect(list.entries[0].descriptions.count == 2)
        #expect(list.entries[1].descriptions.count == 1)
    }

    @Test func `wire payload yields empty list on garbage`() throws {
        let payload = versionHistoryWirePayload(ymlData: Data("%%%not yaml".utf8))
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries.isEmpty)
    }

    @Test func `resolves descriptions in the requested locale`() throws {
        let entries = try YAMLVersionHistoryLoader(data: Data(sampleYAML.utf8), locale: Locale(identifier: "ja-JP"))
            .load()
        #expect(entries[0].descriptions == ["ja-a", "ja-b"])
    }

    /// The Android host is the reason the tag exists: the JNI library's own `Locale.current` reports the Swift
    /// runtime's environment, so without a tag every non-English device would read the English notes.
    @Test func `wire payload localizes to the given language tag`() throws {
        let payload = versionHistoryWirePayload(ymlData: Data(sampleYAML.utf8), languageTag: "ko-KR")
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries[0].descriptions == ["ko-a", "Crash fix"])
    }

    /// Android reports Chinese as zh-CN / zh-TW; the script that picks Hans vs Hant is implied by the region.
    @Test func `wire payload maps chinese regions to scripts`() throws {
        let simplified = try VersionHistoryWireList(
            decoding: versionHistoryWirePayload(ymlData: Data(sampleYAML.utf8), languageTag: "zh-CN"),
        )
        let traditional = try VersionHistoryWireList(
            decoding: versionHistoryWirePayload(ymlData: Data(sampleYAML.utf8), languageTag: "zh-TW"),
        )
        #expect(simplified.entries[0].descriptions.first == "ha")
        #expect(traditional.entries[0].descriptions.first == "ht")
    }

    @Test func `empty language tag falls back to the current locale`() throws {
        let payload = versionHistoryWirePayload(ymlData: Data(sampleYAML.utf8), languageTag: "")
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries.count == 2)
    }
}

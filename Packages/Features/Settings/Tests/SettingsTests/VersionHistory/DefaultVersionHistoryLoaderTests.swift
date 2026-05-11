import Domain
import Foundation
@testable import Settings
import Testing

struct DefaultVersionHistoryLoaderTests {
    private func writeYAML(_ contents: String, name: String = "VersionHistory") throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).yml")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        // swiftlint:disable:next force_unwrapping
        return Bundle(url: dir)!
    }

    @Test func `loads valid YAML`() throws {
        let yaml = """
        - version: 1.1.0
          descriptions:
            - en: Added MIDI import
              ja: MIDI取り込みを追加
        - version: 1.0.0
          descriptions: []
        """
        let bundle = try writeYAML(yaml)
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        let entries = try loader.load()
        #expect(entries.count == 2)
        #expect(entries[0].version == AppVersion(1, 1, 0))
        #expect(entries[1].version == AppVersion(1, 0, 0))
        #expect(entries[1].descriptions.isEmpty)
    }

    @Test func `throws when resource missing`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // swiftlint:disable:next force_unwrapping
        let bundle = try #require(Bundle(url: dir))
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        #expect(throws: (any Error).self) { _ = try loader.load() }
    }

    @Test func `throws when YAML unparseable`() throws {
        let bundle = try writeYAML(":\n  this is\n: not yaml: at all: ::")
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        #expect(throws: (any Error).self) { _ = try loader.load() }
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
        let bundle = try writeYAML(yaml)
        let loader = DefaultVersionHistoryLoader(bundle: bundle)
        let entries = try loader.load()
        #expect(entries.map(\.version) == [AppVersion(1, 1, 0), AppVersion(1, 0, 0)])
    }
}

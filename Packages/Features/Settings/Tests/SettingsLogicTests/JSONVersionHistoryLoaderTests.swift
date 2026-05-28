import Domain
import Foundation
@testable import SettingsLogic
import Testing

/// Tests for JSONVersionHistoryLoader and the versionHistoryWirePayload helper.
///
/// JSON shape must match VersionHistoryEntry's custom init(from:): each entry has a "version" string and a
/// "descriptions" array of locale-keyed objects with "en", "ja", and optional "zh-Hans", "zh-Hant", "ko".
struct JSONVersionHistoryLoaderTests {
    // swiftlint:disable line_length
    /// Minimal two-entry fixture matching the VersionHistory.yml / Android asset shape. Locale strings are
    /// abbreviated stubs so the test owns the shape, not the full translated copy.
    private let sampleJSON =
        """
        [
          {"version":"1.5.1","descriptions":[{"en":"Bug fix","ja":"ja-a","ko":"ko-a","zh-Hans":"ha","zh-Hant":"ht"},{"en":"Crash fix","ja":"ja-b","ko":"ko-b","zh-Hans":"hb","zh-Hant":"hb"}]},
          {"version":"1.5.0","descriptions":[{"en":"Page view","ja":"ja-c","ko":"ko-c","zh-Hans":"hc","zh-Hant":"hc"}]}
        ]
        """
    // swiftlint:enable line_length

    @Test func `loads entries from JSON`() throws {
        let entries = try JSONVersionHistoryLoader(data: Data(sampleJSON.utf8)).load()
        #expect(entries.count == 2)
        #expect(entries[0].version == AppVersion(1, 5, 1))
        #expect(entries[1].version == AppVersion(1, 5, 0))
        // Descriptions are locale-selected at decode time; at minimum they should not be empty.
        #expect(entries[0].descriptions.count == 2)
        #expect(entries[1].descriptions.count == 1)
    }

    @Test func `wire payload round trips`() throws {
        let data = Data(sampleJSON.utf8)
        let payload = versionHistoryWirePayload(jsonData: data)
        let list = try VersionHistoryWireList(decoding: payload)
        #expect(list.entries.count == 2)
        #expect(list.entries[0].version == "1.5.1")
        #expect(list.entries[1].version == "1.5.0")
        // Two descriptions in entry 0, one in entry 1.
        #expect(list.entries[0].descriptions.count == 2)
        #expect(list.entries[1].descriptions.count == 1)
    }
}

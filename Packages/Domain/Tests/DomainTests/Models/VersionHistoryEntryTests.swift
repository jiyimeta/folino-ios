@testable import Domain
import Foundation
import Testing

struct VersionHistoryEntryTests {
    @Test func `decodes english when locale is en`() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {"en": "Added X", "ja": "Xを追加"},
            {"en": "Fixed Y", "ja": "Yを修正"}
          ]
        }
        """#
        let data = Data(json.utf8)

        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "en_US")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: data)

        #expect(entry.version == AppVersion(1, 2, 3))
        #expect(entry.descriptions == ["Added X", "Fixed Y"])
        #expect(entry.id == AppVersion(1, 2, 3))
    }

    @Test func `decodes japanese when locale is ja`() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {"en": "Added X", "ja": "Xを追加"}
          ]
        }
        """#
        let data = Data(json.utf8)

        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "ja_JP")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: data)

        #expect(entry.descriptions == ["Xを追加"])
    }

    @Test func `decodes empty descriptions`() throws {
        let json = #"{"version": "1.0.0", "descriptions": []}"#
        let entry = try JSONDecoder().decode(VersionHistoryEntry.self, from: Data(json.utf8))
        #expect(entry.version == AppVersion(1, 0, 0))
        #expect(entry.descriptions.isEmpty)
    }

    @Test func `decoding fails for malformed version`() {
        let json = #"{"version": "1.x.0", "descriptions": []}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(VersionHistoryEntry.self, from: Data(json.utf8))
        }
    }
}

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

    @Test func `decodes simplified chinese when locale is zh-Hans`() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {
              "en": "Added X", "ja": "Xを追加",
              "zh-Hans": "新增 X", "zh-Hant": "新增 X（繁）", "ko": "X 추가"
            }
          ]
        }
        """#
        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "zh_Hans")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.descriptions == ["新增 X"])
    }

    @Test func `decodes traditional chinese when locale is zh-Hant`() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {
              "en": "Added X", "ja": "Xを追加",
              "zh-Hans": "新增 X", "zh-Hant": "新增 X（繁）", "ko": "X 추가"
            }
          ]
        }
        """#
        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "zh_Hant_TW")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.descriptions == ["新增 X（繁）"])
    }

    @Test func `decodes korean when locale is ko`() throws {
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {
              "en": "Added X", "ja": "Xを追加",
              "zh-Hans": "新增 X", "zh-Hant": "新增 X（繁）", "ko": "X 추가"
            }
          ]
        }
        """#
        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "ko_KR")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.descriptions == ["X 추가"])
    }

    @Test func `falls back to english when new-locale translation is missing`() throws {
        // Entries that predate the zh/ko fields should keep working — the loader
        // should not silently drop them and a zh/ko reader should see English.
        let json = #"""
        {
          "version": "1.2.3",
          "descriptions": [
            {"en": "Added X", "ja": "Xを追加"}
          ]
        }
        """#
        let decoder = JSONDecoder()
        decoder.userInfo[VersionHistoryEntry.localeUserInfoKey] = Locale(identifier: "ko_KR")
        let entry = try decoder.decode(VersionHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.descriptions == ["Added X"])
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

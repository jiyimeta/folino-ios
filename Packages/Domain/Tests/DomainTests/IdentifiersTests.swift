@testable import Domain
import Foundation
import Testing

struct IdentifiersTests {
    @Test func `score item ID is distinct each time`() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        #expect(a != b)
        #expect(a.rawValue != b.rawValue)
    }

    @Test func `score item ID round trips through codable`() throws {
        let id = ScoreItemID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ScoreItemID.self, from: data)
        #expect(decoded == id)
    }

    @Test func `each identifier kind is distinct type`() {
        // Compile-time guarantee: passing a ScoreItemID where a TagID is required must not compile. Runtime guarantee:
        // their UUIDs can collide (extremely unlikely) but the values are still not equatable because they are
        // different types.
        let scoreID = ScoreItemID()
        let tagID = TagID()
        let _: ScoreItemID = scoreID
        let _: TagID = tagID
        // Cannot write `#expect(scoreID == tagID)` — that would not compile, which is the point.
    }
}

struct ReaderPreferencesIDTests {
    @Test func `default raw value is A fresh UUID`() {
        let a = ReaderPreferencesID()
        let b = ReaderPreferencesID()
        #expect(a != b)
    }

    @Test func `round trips through codable`() throws {
        let id = ReaderPreferencesID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ReaderPreferencesID.self, from: data)
        #expect(decoded == id)
    }
}

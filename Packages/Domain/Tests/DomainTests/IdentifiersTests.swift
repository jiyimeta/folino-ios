@testable import Domain
import Foundation
import Testing

@Suite struct IdentifiersTests {
    @Test func scoreItemIDIsDistinctEachTime() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        #expect(a != b)
        #expect(a.rawValue != b.rawValue)
    }

    @Test func scoreItemIDRoundTripsThroughCodable() throws {
        let id = ScoreItemID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ScoreItemID.self, from: data)
        #expect(decoded == id)
    }

    @Test func eachIdentifierKindIsDistinctType() {
        // Compile-time guarantee: passing a ScoreItemID where a TagID is required must not compile.
        // Runtime guarantee: their UUIDs can collide (extremely unlikely) but the values are still
        // not equatable because they are different types.
        let scoreID = ScoreItemID()
        let tagID = TagID()
        let _: ScoreItemID = scoreID
        let _: TagID = tagID
        // Cannot write `#expect(scoreID == tagID)` — that would not compile, which is the point.
    }

    @Test func soundfontPatchKeyEqualsByBankAndProgram() {
        let a = SoundfontPatchKey(bank: 0, program: 4)
        let b = SoundfontPatchKey(bank: 0, program: 4)
        let c = SoundfontPatchKey(bank: 128, program: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func soundfontPatchKeyHashesByBankAndProgram() {
        let set: Set<SoundfontPatchKey> = [
            SoundfontPatchKey(bank: 0, program: 4),
            SoundfontPatchKey(bank: 0, program: 4),
            SoundfontPatchKey(bank: 128, program: 0),
        ]
        #expect(set.count == 2)
    }
}

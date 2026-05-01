@testable import Domain
import Foundation
import Testing

@Suite struct TagTests {
    @Test func roundTripsThroughCodable() throws {
        let tag = Tag(id: TagID(), name: "classical", colorHex: "#3366FF")
        let data = try JSONEncoder().encode(tag)
        let decoded = try JSONDecoder().decode(Domain.Tag.self, from: data)
        #expect(decoded == tag)
    }

    @Test func equalityIsIdentityBased() {
        let id = TagID()
        let a = Tag(id: id, name: "x", colorHex: "#000000")
        let b = Tag(id: id, name: "x", colorHex: "#000000")
        let c = Tag(id: TagID(), name: "x", colorHex: "#000000")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func conformsToIdentifiable() {
        let id = TagID()
        let tag = Tag(id: id, name: "x", colorHex: "#000000")
        #expect(tag.id == id)
    }
}

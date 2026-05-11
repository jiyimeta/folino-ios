@testable import Domain
import Foundation
import Testing

struct UnitRectTests {
    @Test func `clamps values into unit interval`() {
        let r = UnitRect(x: -0.1, y: 1.2, width: 0.5, height: 0.5)
        #expect(r.x == 0)
        #expect(r.y == 1)
        #expect(r.width == 0.5)
        #expect(r.height == 0.5)
    }

    @Test func `clamps width and height so they fit`() {
        let r = UnitRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5)
        #expect(r.x == 0.8)
        #expect(r.y == 0.8)
        #expect(r.width == 0.2)
        #expect(r.height == 0.2)
    }

    @Test func `round trips through codable`() throws {
        let r = UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(UnitRect.self, from: data)
        #expect(decoded == r)
    }
}

struct MusicalAnchorTests {
    @Test func roundTripsThroughCodable() throws {
        let a = MusicalAnchor(systemIndex: 7, normalizedFrame: UnitRect(x: 0, y: 0, width: 1, height: 1))
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(MusicalAnchor.self, from: data)
        #expect(decoded == a)
    }

    @Test func `system index cannot be negative`() {
        let a = MusicalAnchor(systemIndex: -1, normalizedFrame: .zero)
        #expect(a.systemIndex == 0)
    }
}

import Domain
import Foundation
import Testing

@Suite("MixerStripID")
struct MixerStripTests {
    /// The two-element array shape is load-bearing: the persisted override columns hold rows of
    /// `[key0, key1, value]`, and `StaffAddress` encodes the same way — which is what lets the migration be a
    /// filter on the second integer rather than a rewrite.
    @Test func `encodes as a two element array`() throws {
        let data = try JSONEncoder().encode(MixerStripID(partIndex: 2, instrumentOrdinal: 1))

        #expect(String(data: data, encoding: .utf8) == "[2,1]")
    }

    @Test func `round-trips`() throws {
        let id = MixerStripID(partIndex: 3, instrumentOrdinal: 0)

        let decoded = try JSONDecoder().decode(MixerStripID.self, from: JSONEncoder().encode(id))

        #expect(decoded == id)
    }

    @Test func `is usable as a dictionary key`() {
        let a = MixerStripID(partIndex: 0, instrumentOrdinal: 0)
        let b = MixerStripID(partIndex: 0, instrumentOrdinal: 1)

        #expect(Set([a, b, a]).count == 2)
    }
}

@testable import Domain
import Foundation
import Testing

struct MusicalAnchorTests {
    @Test func `round trips through codable`() throws {
        let a = MusicalAnchor(
            measureIndex: 7, tickInMeasure: 480, partIndex: 1,
            staffIndexInPart: 0, dxSp: 1.5, verticalOffsetSp: -2.0,
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(MusicalAnchor.self, from: data)
        #expect(decoded == a)
    }

    @Test func `negative indices clamp to zero`() {
        let a = MusicalAnchor(
            measureIndex: -1, tickInMeasure: -5, partIndex: -2,
            staffIndexInPart: -3, dxSp: -1.0, verticalOffsetSp: -1.0,
        )
        #expect(a.measureIndex == 0)
        #expect(a.tickInMeasure == 0)
        #expect(a.partIndex == 0)
        #expect(a.staffIndexInPart == 0)
        // dxSp / verticalOffsetSp are unconstrained — negative offsets are valid.
        #expect(a.dxSp == -1.0)
        #expect(a.verticalOffsetSp == -1.0)
    }
}

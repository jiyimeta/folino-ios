@testable import Reader
import SheetMusicCore
import Testing

extension Instrument {
    fileprivate static var empty: Instrument { Instrument(id: "") }
}

@Suite struct ScoreFilteringTests {
    private func makeScore() -> Score {
        let part0 = Part(
            id: "P0", trackName: "Violin", instrument: .empty,
            staves: [Staff(staffType: "stdNormal", group: "pitched")]
        )
        let part1 = Part(
            id: "P1", trackName: "Piano", instrument: .empty,
            staves: [
                Staff(staffType: "stdNormal", group: "pitched"),
                Staff(staffType: "stdNormal", group: "pitched"),
            ]
        )
        return Score(
            division: 480,
            parts: [part0, part1],
            metaTags: [:]
        )
    }

    private func address(_ part: Int, _ staff: Int) -> StaffAddress {
        StaffAddress(partIndex: part, staffIndexInPart: staff)
    }

    @Test func emptyHiddenSetReturnsTheSameScore() {
        let score = makeScore()
        let result = score.filtered(hidingStaves: [])
        #expect(result.totalStaffCount == 3)
        #expect(result.parts.count == 2)
    }

    @Test func droppingOneStaffPreservesItsParentPart() {
        let score = makeScore()
        let result = score.filtered(hidingStaves: [address(1, 0)])
        // Part 0 keeps its single staff; Part 1's first staff is dropped,
        // its second staff survives — so Part 1 keeps one staff.
        #expect(result.parts.count == 2)
        #expect(result.parts[0].staves.count == 1)
        #expect(result.parts[1].staves.count == 1)
    }

    @Test func droppingAllStavesOfAPartDropsThePart() {
        let score = makeScore()
        let result = score.filtered(hidingStaves: [address(1, 0), address(1, 1)])
        #expect(result.parts.map(\.id) == ["P0"])
        #expect(result.totalStaffCount == 1)
    }

    @Test func droppingAllStavesReturnsEmptyButValidScore() {
        let score = makeScore()
        let result = score.filtered(
            hidingStaves: [address(0, 0), address(1, 0), address(1, 1)]
        )
        #expect(result.parts.isEmpty)
        #expect(result.totalStaffCount == 0)
    }
}

@testable import Reader
import SheetMusicCore
import Testing

extension Instrument {
    fileprivate static var empty: Instrument { Instrument(id: "") }
}

extension StaffDeclaration {
    /// Synthetic placeholder. The `forStaffID` argument is only for test
    /// readability — `StaffDeclaration` carries no staff ID; matching to
    /// `StaffContent` is positional inside the parent `Part`.
    fileprivate static func placeholder(forStaffID _: Int) -> StaffDeclaration {
        StaffDeclaration(staffType: "stdNormal", group: "pitched")
    }
}

@Suite struct ScoreFilteringTests {
    private func makeScore() -> Score {
        let staff0 = StaffContent(id: 0, measures: [])
        let staff1 = StaffContent(id: 1, measures: [])
        let staff2 = StaffContent(id: 2, measures: [])
        let part0 = Part(
            id: "P0", trackName: "Violin", instrument: .empty,
            staffDeclarations: [.placeholder(forStaffID: 0)]
        )
        let part1 = Part(
            id: "P1", trackName: "Piano", instrument: .empty,
            staffDeclarations: [
                .placeholder(forStaffID: 1),
                .placeholder(forStaffID: 2),
            ]
        )
        return Score(
            division: 480,
            parts: [part0, part1],
            staves: [staff0, staff1, staff2],
            metaTags: [:]
        )
    }

    @Test func emptyHiddenSetReturnsTheSameScore() {
        let score = makeScore()
        let result = score.filtered(hidingStaffIDs: [])
        #expect(result.staves.count == 3)
        #expect(result.parts.count == 2)
    }

    @Test func droppingOneStaffPreservesItsParentPart() {
        let score = makeScore()
        let result = score.filtered(hidingStaffIDs: [1])
        #expect(result.staves.map(\.id) == [0, 2])
        #expect(result.parts.count == 2)
    }

    @Test func droppingAllStavesOfAPartDropsThePart() {
        let score = makeScore()
        let result = score.filtered(hidingStaffIDs: [1, 2])
        #expect(result.staves.map(\.id) == [0])
        #expect(result.parts.map(\.id) == ["P0"])
    }

    @Test func droppingAllStavesReturnsEmptyButValidScore() {
        let score = makeScore()
        let result = score.filtered(hidingStaffIDs: [0, 1, 2])
        #expect(result.staves.isEmpty)
        #expect(result.parts.isEmpty)
    }
}

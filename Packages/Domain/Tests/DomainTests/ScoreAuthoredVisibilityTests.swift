@testable import Domain
import Testing

struct ScoreAuthoredVisibilityTests {
    private func instrument(_ id: String) -> Instrument {
        Instrument(id: id, longName: id)
    }

    @Test func `hidden part contributes all its staves`() {
        // Part 1 is authored-hidden and has two staves; both addresses appear.
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [Staff(measures: [])]),
            Part(
                id: "2", instrument: instrument("b"),
                staves: [Staff(measures: []), Staff(measures: [])],
                isVisibleInScore: false,
            ),
            Part(id: "3", instrument: instrument("c"), staves: [Staff(measures: [])]),
        ])
        #expect(score.authoredHiddenStaffAddresses == [
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ])
    }

    @Test func `all visible score has no authored hidden staves`() {
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [Staff(measures: [])]),
            Part(id: "2", instrument: instrument("b"), staves: [Staff(measures: [])]),
        ])
        #expect(score.authoredHiddenStaffAddresses.isEmpty)
    }
}

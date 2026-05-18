@testable import Reader
import SheetMusicCore
import Testing

extension Instrument {
    fileprivate static var empty: Instrument {
        Instrument(id: "")
    }
}

struct ScoreFilteringTests {
    private func makeScore() -> Score {
        let part0 = Part(
            id: "P0", trackName: "Violin", instrument: .empty,
            staves: [Staff(staffType: "stdNormal", group: "pitched")],
        )
        let part1 = Part(
            id: "P1", trackName: "Piano", instrument: .empty,
            staves: [
                Staff(staffType: "stdNormal", group: "pitched"),
                Staff(staffType: "stdNormal", group: "pitched"),
            ],
        )
        return Score(
            division: 480,
            parts: [part0, part1],
            metaTags: [:],
        )
    }

    private func address(_ part: Int, _ staff: Int) -> StaffAddress {
        StaffAddress(partIndex: part, staffIndexInPart: staff)
    }

    @Test func `empty hidden set returns the same score`() {
        let score = makeScore()
        let result = score.filtered(hidingStaves: [])
        #expect(result.totalStaffCount == 3)
        #expect(result.parts.count == 2)
    }

    @Test func `dropping one staff preserves its parent part`() {
        let score = makeScore()
        let result = score.filtered(hidingStaves: [address(1, 0)])
        // Part 0 keeps its single staff; Part 1's first staff is dropped, its second staff survives — so Part 1 keeps
        // one staff.
        #expect(result.parts.count == 2)
        #expect(result.parts[0].staves.count == 1)
        #expect(result.parts[1].staves.count == 1)
    }

    @Test func `dropping all staves of A part drops the part`() {
        let score = makeScore()
        let result = score.filtered(hidingStaves: [address(1, 0), address(1, 1)])
        #expect(result.parts.map(\.id) == ["P0"])
        #expect(result.totalStaffCount == 1)
    }

    @Test func `dropping all staves returns empty but valid score`() {
        let score = makeScore()
        let result = score.filtered(
            hidingStaves: [address(0, 0), address(1, 0), address(1, 1)],
        )
        #expect(result.parts.isEmpty)
        #expect(result.totalStaffCount == 0)
    }

    // MARK: - Bracket / brace span adjustment

    private func brace(span: Int) -> BracketItem {
        BracketItem(type: .brace, span: span, column: 0, visible: true)
    }

    private func makePianoScore() -> Score {
        // Single piano part with two staves; brace anchored on top staff spans both. Mirrors how MSCX decodes a grand
        // staff.
        let piano = Part(
            id: "P0", trackName: "Piano", instrument: .empty,
            staves: [
                Staff(
                    staffType: "stdNormal",
                    group: "pitched",
                    brackets: [brace(span: 2)],
                ),
                Staff(staffType: "stdNormal", group: "pitched"),
            ],
        )
        return Score(division: 480, parts: [piano], metaTags: [:])
    }

    @Test func `hiding top staff reanchors brace on new top`() {
        let score = makePianoScore()
        let result = score.filtered(hidingStaves: [address(0, 0)])
        // Part survives with one staff. The brace originally on the hidden top staff must now sit on the surviving
        // staff with span = 1.
        #expect(result.parts.count == 1)
        #expect(result.parts[0].staves.count == 1)
        #expect(result.parts[0].staves[0].brackets.map(\.type) == [.brace])
        #expect(result.parts[0].staves[0].brackets.map(\.span) == [1])
    }

    @Test func `hiding bottom staff shrinks brace span`() {
        let score = makePianoScore()
        let result = score.filtered(hidingStaves: [address(0, 1)])
        // Top staff still carries the brace, but its span has shrunk to 1 because the bottom staff of the original
        // group is gone.
        #expect(result.parts[0].staves.count == 1)
        #expect(result.parts[0].staves[0].brackets.map(\.span) == [1])
    }

    private func makeThreeStaffBracketScore() -> Score {
        // Three-staff part with one normal bracket on top spanning all 3.
        let part = Part(
            id: "P0", trackName: "Choir", instrument: .empty,
            staves: [
                Staff(
                    staffType: "stdNormal",
                    group: "pitched",
                    brackets: [BracketItem(type: .normal, span: 3)],
                ),
                Staff(staffType: "stdNormal", group: "pitched"),
                Staff(staffType: "stdNormal", group: "pitched"),
            ],
        )
        return Score(division: 480, parts: [part], metaTags: [:])
    }

    @Test func `hiding middle staff shrinks bracket span by one`() {
        let score = makeThreeStaffBracketScore()
        let result = score.filtered(hidingStaves: [address(0, 1)])
        // Bracket originally covered three staves; after hiding the middle one only two remain in its group.
        #expect(result.parts[0].staves.count == 2)
        #expect(result.parts[0].staves[0].brackets.map(\.span) == [2])
        #expect(result.parts[0].staves[1].brackets.isEmpty)
    }

    @Test func `hiding top of three reanchors bracket with reduced span`() {
        let score = makeThreeStaffBracketScore()
        let result = score.filtered(hidingStaves: [address(0, 0)])
        // After hiding the top, the bracket should re-anchor on the new top staff (was index 1) with span = 2.
        #expect(result.parts[0].staves.count == 2)
        #expect(result.parts[0].staves[0].brackets.map(\.type) == [.normal])
        #expect(result.parts[0].staves[0].brackets.map(\.span) == [2])
    }

    @Test func `bracket does not leak onto staves outside original span`() {
        // Two parts, each with its own brace. Hiding the bottom staff of part 0 must not extend part 0's brace into
        // part 1.
        let part0 = Part(
            id: "P0", trackName: "Piano", instrument: .empty,
            staves: [
                Staff(brackets: [brace(span: 2)]),
                Staff(),
            ],
        )
        let part1 = Part(
            id: "P1", trackName: "Organ", instrument: .empty,
            staves: [Staff(), Staff()],
        )
        let score = Score(division: 480, parts: [part0, part1], metaTags: [:])
        let result = score.filtered(hidingStaves: [address(0, 1)])
        #expect(result.parts.count == 2)
        #expect(result.parts[0].staves[0].brackets.map(\.span) == [1])
        // Part 1 still has its two staves and no brackets leaked in.
        #expect(result.parts[1].staves.count == 2)
        #expect(result.parts[1].staves.flatMap(\.brackets).isEmpty)
    }
}

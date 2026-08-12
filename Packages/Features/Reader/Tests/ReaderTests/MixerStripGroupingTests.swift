import Domain
@testable import Reader
import Testing

/// The playback mixer draws one row per STRIP, grouped under a part header when a part is not one strip over one
/// staff. Both decisions are pure logic over the engine's strip list, so they are pinned here rather than left to a
/// visual check of the inspector.
struct MixerStripGroupingTests {
    private static func strip(
        part: Int, ordinal: Int, partName: String, instrumentName: String,
    ) -> MixerStrip {
        MixerStrip(
            id: MixerStripID(partIndex: part, instrumentOrdinal: ordinal),
            partName: partName, instrumentName: instrumentName,
            defaultVolume: 0.8, defaultProgram: 0, isDrums: false,
        )
    }

    @Test func `a part with one strip over one staff collapses to a single unheaded row`() {
        let strips = [Self.strip(part: 0, ordinal: 0, partName: "Violin", instrumentName: "Violin")]

        let groups = strips.grouped()

        #expect(groups.count == 1)
        #expect(groups[0].strips.count == 1)
        #expect(groups[0].drawsHeader(staffCount: 1) == false)
    }

    @Test func `a part with one strip over two staves draws a header`() {
        let strips = [Self.strip(part: 0, ordinal: 0, partName: "Piano", instrumentName: "Piano")]

        let group = strips.grouped()[0]

        // A grand staff: one sound, two staves. The header is the only thing that corresponds to that SET of staves,
        // so it has to exist for their eyes to have a home.
        #expect(group.drawsHeader(staffCount: 2))
        // ...and the single row underneath stays unlabelled — the header already said "Piano".
        #expect(group.rowLabel(for: group.strips[0]) == nil)
    }

    @Test func `a part with two strips draws a header over two labelled rows`() {
        let strips = [
            Self.strip(part: 0, ordinal: 0, partName: "Keyboard", instrumentName: "Piano"),
            Self.strip(part: 0, ordinal: 1, partName: "Keyboard", instrumentName: "Accordion"),
        ]

        let groups = strips.grouped()

        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.partName == "Keyboard")
        // Two sounds on one staff still needs the header, so the rows can be told apart by instrument.
        #expect(group.drawsHeader(staffCount: 1))
        #expect(group.strips.map { group.rowLabel(for: $0) } == ["Piano", "Accordion"])
    }

    @Test func `groups and their strips keep the engine's order rather than being sorted`() {
        // Deliberately out of numeric order: the engine's list IS the order, and re-sorting it would reorder the
        // mixer against the score the user is looking at.
        let strips = [
            Self.strip(part: 2, ordinal: 1, partName: "Cello", instrumentName: "Pizzicato"),
            Self.strip(part: 2, ordinal: 0, partName: "Cello", instrumentName: "Cello"),
            Self.strip(part: 0, ordinal: 0, partName: "Violin", instrumentName: "Violin"),
        ]

        let groups = strips.grouped()

        #expect(groups.map(\.partIndex) == [2, 0])
        #expect(groups[0].strips.map(\.instrumentName) == ["Pizzicato", "Cello"])
    }

    @Test func `a group takes its name from its first strip and its id from its part`() {
        let strips = [
            Self.strip(part: 3, ordinal: 0, partName: "Percussion", instrumentName: "Drum Kit"),
            Self.strip(part: 3, ordinal: 1, partName: "Percussion", instrumentName: "Timpani"),
        ]

        let group = strips.grouped()[0]

        #expect(group.partName == "Percussion")
        #expect(group.id == 3)
    }

    @Test func `an empty strip list groups to nothing`() {
        // The mixer is empty until a score is prepared — there is no engine to describe before then.
        #expect([MixerStrip]().grouped().isEmpty)
    }
}

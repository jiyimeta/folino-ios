@testable import Reader
import SheetMusicCore
import Testing

struct ScoreApplyingClefOverridesTests {
    @Test func `empty overrides returns equal score`() {
        let score = makeScore(staffDefaultClefs: ["G", "F"])
        let result = score.applying(clefOverrides: [:])
        #expect(result == score)
    }

    @Test func `override rewrites explicit measure 0 clef`() {
        // Staff with an explicit measure-0 clef change as the very first
        // voice element on voice 0.
        var score = makeScore(staffDefaultClefs: [nil])
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "G8vb"])
        guard case let .clef(rewritten) =
            result.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { Issue.record("expected rewritten clef"); return }
        #expect(rewritten.concertClefType == "G8vb")
    }

    @Test func `override sets default clef when no explicit measure 0 clef`() {
        var score = makeScore(staffDefaultClefs: [nil])
        // Voice 0 starts with a chord, not a clef.
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .rest(duration: .whole),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "F"])
        #expect(result.parts[0].staves[0].defaultClefType == "F")
        // Original measure 0 element 0 is untouched.
        if case .clef = result.parts[0].staves[0].measures[0].voices[0].elements[0] {
            Issue.record("override must not insert a clef voice element")
        }
    }

    @Test func `mid score clef change preserved`() {
        var score = makeScore(staffDefaultClefs: [nil])
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .rest(duration: .whole),
                ]),
            ]),
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "F")),
                    .rest(duration: .whole),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "G8vb"])
        // Measure 0 element 0 → rewritten.
        if case let .clef(c) =
            result.parts[0].staves[0].measures[0].voices[0].elements[0]
        {
            #expect(c.concertClefType == "G8vb")
        } else {
            Issue.record("measure 0 clef rewrite missing")
        }
        // Measure 1 element 0 → preserved.
        if case let .clef(c) =
            result.parts[0].staves[0].measures[1].voices[0].elements[0]
        {
            #expect(c.concertClefType == "F")
        } else {
            Issue.record("mid-score clef change must be preserved")
        }
    }

    @Test func `override clears transposing clef type`() {
        var score = makeScore(staffDefaultClefs: [nil])
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(
                        concertClefType: "G",
                        transposingClefType: "G8vb",
                    )),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "F"])
        guard case let .clef(rewritten) =
            result.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { Issue.record("expected rewritten clef"); return }
        #expect(rewritten.concertClefType == "F")
        #expect(rewritten.transposingClefType == nil)
    }

    @Test func `override for non existent staff is no op`() {
        let score = makeScore(staffDefaultClefs: ["G"])
        let result = score.applying(clefOverrides: [
            StaffAddress(partIndex: 99, staffIndexInPart: 0): "G8vb",
        ])
        #expect(result == score)
    }

    /// Builds a Score with N staves under one Part. Each entry in
    /// `staffDefaultClefs` becomes one staff with that defaultClefType
    /// and one empty measure (so layout has something to anchor to).
    private func makeScore(staffDefaultClefs: [String?]) -> Score {
        let staves = staffDefaultClefs.map { rawType in
            Staff(
                defaultClefType: rawType,
                measures: [Measure(voices: [Voice(elements: [])])],
            )
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "P0",
                    instrument: Instrument(id: "x", channels: []),
                    staves: staves,
                ),
            ],
            metaTags: [:],
        )
    }
}

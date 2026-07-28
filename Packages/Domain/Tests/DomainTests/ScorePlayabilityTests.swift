@testable import Domain
import Testing

struct ScorePlayabilityTests {
    private func instrument(_ id: String) -> Instrument {
        Instrument(id: id, longName: id)
    }

    private func note(pitch: Int = 60) -> Note {
        Note(pitch: pitch, tpc: 14)
    }

    private func rest() -> VoiceElement {
        .rest(duration: .quarter)
    }

    private func chord(_ notes: Note...) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: ChordNotes(notes)))
    }

    @Test func `score with only rests has nothing playable`() {
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [
                Staff(measures: [
                    Measure(voices: [Voice(elements: [rest(), rest()])]),
                    Measure(voices: [Voice(elements: [rest()])]),
                ]),
            ]),
        ])
        #expect(!score.hasPlayableContent)
    }

    @Test func `score with no measures at all has nothing playable`() {
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [Staff(measures: [])]),
        ])
        #expect(!score.hasPlayableContent)
    }

    @Test func `score with no parts has nothing playable`() {
        let score = Score(division: 480, parts: [])
        #expect(!score.hasPlayableContent)
    }

    @Test func `a single note buried deep in the score is enough`() {
        // Playable note lives in the second part's second staff, second measure, second voice —
        // exercises that the traversal doesn't stop early on the wrong axis.
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [rest()])])]),
            ]),
            Part(id: "2", instrument: instrument("b"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [rest()])])]),
                Staff(measures: [
                    Measure(voices: [Voice(elements: [rest()])]),
                    Measure(voices: [
                        Voice(elements: [rest()]),
                        Voice(elements: [chord(note())]),
                    ]),
                ]),
            ]),
        ])
        #expect(score.hasPlayableContent)
    }

    @Test func `non-temporal elements alone are not playable`() {
        let elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ]
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: elements)])]),
            ]),
        ])
        #expect(!score.hasPlayableContent)
    }

    @Test func `a chord with at least one note is playable`() {
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [chord(note())])])]),
            ]),
        ])
        #expect(score.hasPlayableContent)
    }

    @Test func `playableElementCount counts every playable chord, not just the first`() {
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [
                Staff(measures: [
                    Measure(voices: [Voice(elements: [chord(note()), rest(), chord(note(pitch: 62))])]),
                    Measure(voices: [Voice(elements: [rest()])]),
                ]),
            ]),
        ])
        #expect(score.playableElementCount == 2)
        #expect(score.hasPlayableContent)
    }

    @Test func `playableElementCount is zero for an all-rests score`() {
        let score = Score(division: 480, parts: [
            Part(id: "1", instrument: instrument("a"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [rest(), rest()])])]),
            ]),
        ])
        #expect(score.playableElementCount == 0)
    }
}

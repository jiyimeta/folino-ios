import Domain // re-exports SheetMusicCore
import Foundation

enum EditorFixtures {
    static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// One part, one staff, one measure of four quarter rests in 4/4.
    /// Voice elements: [0] timeSignature(4/4), [1..4] rest(quarter).
    static func fourQuarterRests() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// Same, but element index 1 is a quarter chord on C4 (pitch 60, tpc 14).
    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let id = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        return score
    }

    static func restID(element: Int) -> RestID {
        RestID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    static func noteID(element: Int, noteIndex: Int = 0) -> NoteID {
        NoteID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: noteIndex)
    }

    static func sampleItem() -> ScoreItem {
        ScoreItem(
            title: "Test Score",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "score.mscz",
            contentHash: "0",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

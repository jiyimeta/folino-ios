import Domain // re-exports SheetMusicCore
import Foundation

/// The few score shapes `EditorCoreTests` needs, duplicated rather than shared.
///
/// `EditorTests/Support/EditorFixtures.swift` is the older, larger twin: it carries a dozen more shapes, all of them
/// for suites that still live in `EditorTests`. A test target cannot see another test target's sources, and depending
/// on `EditorTests` to reach them would make the platform-neutral suite depend on the Apple-only one — the exact
/// coupling `EditorCore` exists to avoid. Task 12 moves the remaining logic suites across and reconciles the two.
enum EditorCoreFixtures {
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

    /// Same, but element index 1 is a one-note quarter chord on C4 (pitch 60, tpc 14).
    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let id = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        return score
    }

    static func restID(measure: Int = 0, element: Int) -> RestID {
        RestID(staff: staff0, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    static func noteID(measure: Int = 0, element: Int, noteIndex: Int = 0) -> NoteID {
        NoteID(
            staff: staff0,
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: element,
            noteIndexInChord: noteIndex,
        )
    }
}

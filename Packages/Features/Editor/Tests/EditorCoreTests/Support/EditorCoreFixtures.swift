import Domain // re-exports SheetMusicCore
import EditorCore
import Foundation

// Imported by name, and every `ScoreItemID` below is qualified, because Domain declares a DIFFERENT `ScoreItemID`: a
// library item's identifier. See `SelectionRederivation.swift`'s note — same collision, same fix.
import SheetMusicCore

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

    // MARK: - EditorSessionCore

    /// A session core wired to no-op fakes for the two save-path seams (`FileFactsProviding`, `ScoreFileWriting`).
    /// `EditorRelayRecordingTests` never saves, so neither fake is ever called — they exist only so a real
    /// `EditorSessionCore` can be constructed. `recordsRelayIntents` defaults to `false`, matching the core's own
    /// default, so a bare `makeCore()` documents the recording-off case as plainly as passing the flag documents the
    /// on case.
    static func makeCore(recordsRelayIntents: Bool = false) -> EditorSessionCore {
        EditorSessionCore(
            scoreItem: ScoreItem(
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
            ),
            scoresDirectory: FileManager.default.temporaryDirectory,
            fileFacts: NoOpFileFacts(),
            writer: NoOpScoreWriter(),
            recordsRelayIntents: recordsRelayIntents,
        )
    }

    /// The first rest in `score`'s single part/staff, scanned rather than hardcoded to an element index so it stays
    /// correct whatever fixture score it is pointed at.
    static func firstRestItem(in score: Score) -> SheetMusicCore.ScoreItemID {
        for (measureIndex, measure) in score.parts[0].staves[0].measures.enumerated() {
            for (voiceIndex, voice) in measure.voices.enumerated() {
                for (elementIndex, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element, chord.notes.isEmpty else { continue }
                    return .rest(RestID(
                        staff: staff0, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                    ))
                }
            }
        }
        fatalError("firstRestItem(in:): no rest in the given score")
    }
}

/// Satisfies `FileFactsProviding` without touching the filesystem — see `makeCore`'s doc for why this is never
/// actually called.
private struct NoOpFileFacts: FileFactsProviding {
    func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        ("0", 0)
    }
}

/// Satisfies `ScoreFileWriting` without touching the filesystem. Same rationale as `NoOpFileFacts`.
private struct NoOpScoreWriter: ScoreFileWriting {
    func write(_ score: Score, to url: URL, format: ScoreFormat) throws {}
    func refreshRow(_ item: ScoreItem) throws {}
}

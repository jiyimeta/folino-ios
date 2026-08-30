@testable import EditorCore
import SheetMusicCore
import Testing

@Suite("DrumPadLayout")
struct DrumPadLayoutTests {
    private static let staff = EditorCoreFixtures.staff0

    @Test
    func `the default layout is a realistic kit, cymbals first`() {
        let layout = DrumPadLayout.default
        #expect(layout.keys.map(\.pitch) == [42, 46, 51, 49, 38, 37, 50, 48, 47, 45, 43, 41, 36, 44, 56])
        #expect(layout.rowCount == 2)
        // Every pitch is one the GM table names, so no key can render as "Drum 63".
        for key in layout.keys {
            #expect(GMDrumset.entries[key.pitch] != nil)
        }
    }

    @Test
    func `a default key carries the GM head, line and name`() {
        let hiHat = DrumPadLayout.default.keys.first { $0.pitch == 42 }
        #expect(hiHat?.headType == "cross")
        #expect(hiHat?.line == -1)
        #expect(hiHat?.name == "Closed Hi-Hat")
    }

    @Test
    func `the row count clamps to one through three`() {
        #expect(DrumPadLayout(keys: [], rowCount: 0).rowCount == 1)
        #expect(DrumPadLayout(keys: [], rowCount: 4).rowCount == 3)
        #expect(DrumPadLayout(keys: [], rowCount: 2).rowCount == 2)
    }

    /// A chart that puts the ride somewhere of its own must keep that line — the pad is for correcting the file in
    /// front of you, and a key drawn where the file does not put it would lie about what pressing it does.
    @Test
    func `a score's own drumset overrides the GM line and head`() {
        var instrument = Instrument(id: "drumset", useDrumset: true)
        instrument.drumset = [
            51: DrumsetEntry(name: "Ride (my chart)", head: "diamond", line: 3, voiceIndex: 0, stem: 1),
        ]

        let resolved = DrumPadLayout.default.resolved(against: instrument)

        let ride = resolved.keys.first { $0.pitch == 51 }
        #expect(ride?.line == 3)
        #expect(ride?.headType == "diamond")
        // Pitches the file says nothing about keep the GM answer.
        #expect(resolved.keys.first { $0.pitch == 42 }?.line == -1)
    }

    @Test
    func `the single-voice preset puts every key in voice one`() {
        let applied = DrumVoicePreset.singleVoice.applied(to: .default)
        #expect(applied.keys.allSatisfy { $0.voiceIndex == 0 })
    }

    @Test
    func `hands and feet is the GM split: bass drum, pedal hi-hat, low floor tom`() {
        let applied = DrumVoicePreset.handsAndFeet.applied(to: .default)
        let feet = applied.keys.filter { $0.voiceIndex == 1 }.map(\.pitch).sorted()
        #expect(feet == [36, 41, 44])
    }

    @Test
    func `a one-voice drum staff implies the single-voice preset`() {
        let score = Self.drumScore(voicesPerMeasure: [1, 1])
        #expect(DrumVoicePreset.implied(by: score, staff: Self.staff) == .singleVoice)
    }

    @Test
    func `any two-voice bar implies hands and feet`() {
        let score = Self.drumScore(voicesPerMeasure: [1, 2])
        #expect(DrumVoicePreset.implied(by: score, staff: Self.staff) == .handsAndFeet)
    }

    private static func drumScore(voicesPerMeasure: [Int]) -> Score {
        let measures = voicesPerMeasure.map { count in
            Measure(voices: (0 ..< count).map { _ in Voice(elements: [.rest(duration: .measure)]) })
        }
        let staffValue = Staff(measures: measures)
        let part = Part(
            id: "1",
            instrument: Instrument(id: "drumset", useDrumset: true, drumLineMap: GMPercussion.drumLineMap),
            staves: [staffValue],
        )
        return Score(division: 480, parts: [part])
    }
}

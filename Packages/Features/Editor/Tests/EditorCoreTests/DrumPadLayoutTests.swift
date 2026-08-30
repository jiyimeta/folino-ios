@testable import EditorCore
import Foundation
import SheetMusicCore
import Testing

@Suite("DrumPadLayout")
struct DrumPadLayoutTests {
    private static let staff = EditorCoreFixtures.staff0

    @Test
    func `the default layout is a realistic kit, cymbals above drums`() {
        let layout = DrumPadLayout.default
        #expect(layout.keys.map(\.pitch) == [42, 46, 44, 49, 57, 51, 56, 38, 37, 50, 47, 45, 43, 36])
        #expect(layout.rowCount == 2)
        // Seven and seven: each row of the pad closes with a key of its own (the rest above, the ⋯ menu below),
        // so an even split is what makes the two rows the same width.
        #expect(layout.keys.count.isMultiple(of: layout.rowCount))
        // Every pitch is one the GM table names, so no key can render as "Drum 63".
        for key in layout.keys {
            #expect(GMDrumset.entries[key.pitch] != nil)
        }
    }

    /// Four toms, not GM's six: the two that go are the ones a chart is least likely to use, and a file that does
    /// use them reaches them through the pad's ⋯ menu instead.
    @Test
    func `the default layout leaves the hi-mid and low floor toms off`() {
        let pitches = Set(DrumPadLayout.default.keys.map(\.pitch))
        #expect(!pitches.contains(48))
        #expect(!pitches.contains(41))
        #expect(pitches.isSuperset(of: [50, 47, 45, 43]))
        // Both crashes, because the pair is what the mirrored tilt in their icons is for.
        #expect(pitches.isSuperset(of: [49, 57]))
    }

    @Test
    func `a default key carries the GM head, line and name`() {
        let hiHat = DrumPadLayout.default.keys.first { $0.pitch == 42 }
        #expect(hiHat?.headType == "cross")
        #expect(hiHat?.line == -1)
        #expect(hiHat?.name == "Closed Hi-Hat")
    }

    @Test
    func `splitting a flat list clamps the row count to one through three`() {
        #expect(DrumPadLayout(keys: [], rowCount: 0).rowCount == 1)
        #expect(DrumPadLayout(keys: [], rowCount: 4).rowCount == 1)
        let six = [36, 38, 42, 45, 49, 51].compactMap { DrumPadKey(gmPitch: $0) }
        #expect(DrumPadLayout(keys: six, rowCount: 2).rows.map(\.count) == [3, 3])
        #expect(DrumPadLayout(keys: six, rowCount: 4).rows.map(\.count) == [2, 2, 2])
    }

    /// Rows may differ in length now, so the pad draws what the layout says instead of chopping a flat list in
    /// half. Nothing caps a row: an iPad has room a phone does not.
    @Test
    func `rows are kept as written, uneven or long`() {
        let layout = DrumPadLayout(rows: [
            [42, 46].compactMap { DrumPadKey(gmPitch: $0) },
            [36, 38, 40, 41, 43, 45, 47, 48, 50].compactMap { DrumPadKey(gmPitch: $0) },
        ])
        #expect(layout.rows.map(\.count) == [2, 9])
        #expect(layout.rowCount == 2)
        #expect(layout.keys.map(\.pitch) == [42, 46, 36, 38, 40, 41, 43, 45, 47, 48, 50])
    }

    /// A pad arranged by hand before rows were stored is a flat list plus a count. Falling back to the default kit
    /// would throw that arrangement away.
    @Test
    func `a layout stored in the old flat shape still decodes`() throws {
        let stored = Data(#"""
        {"keys":[{"pitch":42,"name":"Closed Hi-Hat","headType":"cross","line":-1,"voiceIndex":0},
        {"pitch":38,"name":"Acoustic Snare","headType":"normal","line":2,"voiceIndex":0},
        {"pitch":36,"name":"Bass Drum 1","headType":"normal","line":6,"voiceIndex":1},
        {"pitch":51,"name":"Ride Cymbal 1","headType":"cross","line":0,"voiceIndex":0}],"rowCount":2}
        """#.utf8)
        let decoded = try JSONDecoder().decode(DrumPadLayout.self, from: stored)
        #expect(decoded.rows.map { $0.map(\.pitch) } == [[42, 38], [36, 51]])

        // And it re-encodes in the new shape, so the migration happens once.
        let round = try JSONDecoder().decode(DrumPadLayout.self, from: JSONEncoder().encode(decoded))
        #expect(round == decoded)
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

    /// GM puts the bass drum, the pedal hi-hat and the low floor tom in the feet. The default layout no longer
    /// carries the low floor tom, so only the first two can turn up here — but the rule is the table's, not the
    /// layout's, which is what the second half checks.
    @Test
    func `hands and feet is the GM split: bass drum, pedal hi-hat, low floor tom`() {
        let applied = DrumVoicePreset.handsAndFeet.applied(to: .default)
        let feet = applied.keys.filter { $0.voiceIndex == 1 }.map(\.pitch).sorted()
        #expect(feet == [36, 44])

        let withFloorTom = DrumVoicePreset.handsAndFeet.applied(
            to: DrumPadLayout(rows: [[36, 41, 44, 42].compactMap { DrumPadKey(gmPitch: $0) }]),
        )
        #expect(withFloorTom.keys.filter { $0.voiceIndex == 1 }.map(\.pitch).sorted() == [36, 41, 44])
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

@testable import Audio
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore
import Testing

@MainActor
struct LivePlaybackControllerTests {
    // MARK: - Loop bounds

    @Test func `loop bounds resolves to first and last item I ds across measures`() {
        let score = makeMeasureScore(measureCount: 4)
        let range = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0),
        )

        let bounds = LivePlaybackController.loopBounds(for: range, in: score)

        // Each measure in `makeMeasureScore` carries a single quarter-note rest at element index 0. Both endpoints
        // resolve to .rest IDs.
        if case let .rest(startID) = bounds?.start {
            #expect(startID.measureIndex == 1)
            #expect(startID.elementIndex == 0)
        } else {
            Issue.record("expected .rest start, got \(String(describing: bounds?.start))")
        }
        if case let .rest(lastID) = bounds?.last {
            #expect(lastID.measureIndex == 2)
            #expect(lastID.elementIndex == 0)
        } else {
            Issue.record("expected .rest last, got \(String(describing: bounds?.last))")
        }
    }

    @Test func `loop bounds returns nil when end measure past score`() {
        let score = makeMeasureScore(measureCount: 2)
        let range = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 5, voiceIndex: 0, chordIndex: 0),
        )

        #expect(LivePlaybackController.loopBounds(for: range, in: score) == nil)
    }

    @Test func `first score item ID returns note ID for chord with notes`() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let measure = Measure(voices: [
            Voice(elements: [.chord(chord), .rest(duration: .quarter)]),
        ])
        let score = makeSingleMeasureScore(measure: measure)

        let id = LivePlaybackController.firstScoreItemID(inMeasure: 0, of: score)

        if case let .note(noteID) = id {
            #expect(noteID.measureIndex == 0)
            #expect(noteID.elementIndex == 0)
            #expect(noteID.noteIndexInChord == 0)
        } else {
            Issue.record("expected .note, got \(String(describing: id))")
        }
    }

    @Test func `last score item ID returns note ID for chord with notes`() {
        // MIDI 60 = middle C, TPC 14 = "C natural" in MuseScore's tonal pitch class numbering. Concrete values don't
        // matter — we only need a `Chord` whose `notes` is non-empty so `lastScoreItemID` returns `.note(...)` rather
        // than `.rest(...)`.
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let measure = Measure(voices: [
            Voice(elements: [.rest(duration: .quarter), .chord(chord)]),
        ])
        let score = makeSingleMeasureScore(measure: measure)

        let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)

        if case let .note(noteID) = id {
            #expect(noteID.measureIndex == 0)
            #expect(noteID.elementIndex == 1) // second element in the voice
            #expect(noteID.noteIndexInChord == 0)
        } else {
            Issue.record("expected .note, got \(String(describing: id))")
        }
    }

    @Test func `last score item ID returns nil for measure with no chord elements`() {
        let measure = Measure(voices: [Voice(elements: [])])
        let score = makeSingleMeasureScore(measure: measure)

        let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)
        #expect(id == nil)
    }
}

// MARK: - Fixtures

/// Builds a single-part, single-staff score with `measureCount` measures, each containing a single quarter-note rest on
/// voice 0 (rests are the unified empty-chord representation, which is what the cursor timeline keys via
/// `.rest(RestID)`).
private func makeMeasureScore(measureCount: Int) -> Score {
    let measures = (0 ..< measureCount).map { _ in
        Measure(voices: [Voice(elements: [.rest(duration: .quarter)])])
    }
    let staff = Staff(measures: measures)
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff],
    )
    return Score(division: 480, parts: [part])
}

/// Builds a single-part, single-staff, single-measure score with the given `Measure`. Used by `firstScoreItemID` /
/// `lastScoreItemID` tests that need to specify exact voice content.
private func makeSingleMeasureScore(measure: Measure) -> Score {
    let staff = Staff(measures: [measure])
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff],
    )
    return Score(division: 480, parts: [part])
}

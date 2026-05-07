@testable import Audio
import Domain
import Foundation
import SheetMusicCore
import Testing

@MainActor
@Suite struct LivePlaybackControllerTests {
    /// Resolver probe that reports a fixed set of `(bank, program, isDrums)`
    /// triples as "precisely available", everything else as missing.
    private struct StubProbe: PrecisePatchProbe {
        struct Triple: Hashable { let bank: Int; let program: Int; let isDrums: Bool }
        let available: Set<Triple>

        func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL? {
            available.contains(.init(bank: bank, program: program, isDrums: isDrums))
                ? URL(fileURLWithPath: "/dev/null")
                : nil
        }
    }

    @Test func pitchedStaffWithMissingPatchRewritesToFlute() {
        let score = makeScore(parts: [.pitched(bank: 5, program: 42)])
        let probe = StubProbe(available: [])

        let result = LivePlaybackController.scoreWithFallbackRewrites(score, probe: probe)
        let channel = firstChannel(of: result, partIndex: 0)
        #expect(channel.bank == 0)
        #expect(channel.program == 73)
    }

    @Test func drumStaffWithMissingPatchRewritesToStandardKit() {
        let score = makeScore(parts: [.drums(bank: 0, program: 0)])
        let probe = StubProbe(available: [])

        let result = LivePlaybackController.scoreWithFallbackRewrites(score, probe: probe)
        let channel = firstChannel(of: result, partIndex: 0)
        #expect(channel.bank == 0)
        #expect(channel.program == 0)
        // Sanity: the part is still flagged as drums.
        #expect(result.parts[0].instrument.useDrumset)
    }

    @Test func availablePatchPassesThrough() {
        let score = makeScore(parts: [.pitched(bank: 8, program: 0)])
        let probe = StubProbe(available: [.init(bank: 8, program: 0, isDrums: false)])

        let result = LivePlaybackController.scoreWithFallbackRewrites(score, probe: probe)
        let channel = firstChannel(of: result, partIndex: 0)
        #expect(channel.bank == 8)
        #expect(channel.program == 0)
    }

    // MARK: - Loop bounds

    @Test func loopBoundsUsesBeatRangeWhenEndIsNotLastMeasure() {
        let score = makeMeasureScore(measureCount: 4)
        let range = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        )

        let bounds = LivePlaybackController.loopBounds(for: range, in: score)

        guard case let .beatRange(start, end) = bounds else {
            Issue.record("expected .beatRange, got \(String(describing: bounds))")
            return
        }
        #expect(start == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(end == .beat(measureIndex: 3, tickInMeasure: 0))
    }

    @Test func loopBoundsUsesThroughEndOfWhenEndIsLastMeasure() {
        let score = makeMeasureScore(measureCount: 3)
        let range = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        )

        let bounds = LivePlaybackController.loopBounds(for: range, in: score)

        guard case let .throughEndOf(start, last) = bounds else {
            Issue.record("expected .throughEndOf, got \(String(describing: bounds))")
            return
        }
        #expect(start == .beat(measureIndex: 1, tickInMeasure: 0))
        // The last element in measure 2 is a quarter-note rest at element index 0.
        if case let .rest(restID) = last {
            #expect(restID.measureIndex == 2)
            #expect(restID.voiceIndex == 0)
            #expect(restID.elementIndex == 0)
        } else {
            Issue.record("expected .rest, got \(last)")
        }
    }

    @Test func lastScoreItemIDReturnsNoteIDForChordWithNotes() {
        // MIDI 60 = middle C, TPC 14 = "C natural" in MuseScore's tonal pitch
        // class numbering. Concrete values don't matter — we only need a
        // `Chord` whose `notes` is non-empty so `lastScoreItemID` returns
        // `.note(...)` rather than `.rest(...)`.
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)]
        )
        let measure = Measure(voices: [
            Voice(elements: [.rest(duration: .quarter), .chord(chord)]),
        ])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])

        let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)

        if case let .note(noteID) = id {
            #expect(noteID.measureIndex == 0)
            #expect(noteID.elementIndex == 1) // second element in the voice
            #expect(noteID.noteIndexInChord == 0)
        } else {
            Issue.record("expected .note, got \(String(describing: id))")
        }
    }

    @Test func lastScoreItemIDReturnsNilForMeasureWithNoChordElements() {
        let measure = Measure(voices: [Voice(elements: [])])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])

        let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)
        #expect(id == nil)
    }
}

// MARK: - Fixtures

/// Shorthand for the kind of part a test wants to fabricate.
private enum PartSpec {
    case pitched(bank: Int, program: Int)
    case drums(bank: Int, program: Int)
}

/// Builds a minimal `Score` whose parts each carry a single pitched-or-drum
/// staff with one `InstrumentChannel` set to the requested bank/program.
/// Everything else is left at the default values supplied by
/// `swift-sheet-music`'s public initializers — measures stay empty,
/// which is fine for `scoreWithFallbackRewrites`: that helper only
/// inspects `parts[i].instrument` and `score.allStaves`.
private func makeScore(parts specs: [PartSpec]) -> Score {
    let parts: [Part] = specs.enumerated().map { index, spec in
        switch spec {
        case let .pitched(bank, program):
            let channel = InstrumentChannel(program: program, bank: bank)
            let instrument = Instrument(id: "pitched-\(index)", channels: [channel])
            return Part(
                id: "P\(index)",
                instrument: instrument,
                staves: [Staff()]
            )
        case let .drums(bank, program):
            let channel = InstrumentChannel(program: program, bank: bank)
            let instrument = Instrument(
                id: "drums-\(index)",
                channels: [channel],
                useDrumset: true
            )
            return Part(
                id: "P\(index)",
                instrument: instrument,
                staves: [Staff(group: "percussion")]
            )
        }
    }
    return Score(division: 480, parts: parts)
}

/// First `InstrumentChannel` of the part at `partIndex`. Falls back to a
/// default-constructed channel if the part has none, mirroring the
/// helper's own defensive behaviour.
private func firstChannel(of score: Score, partIndex: Int) -> InstrumentChannel {
    score.parts[partIndex].instrument.channels.first ?? InstrumentChannel()
}

/// Builds a single-part, single-staff score with `measureCount` measures,
/// each containing a single quarter-note chord on voice 0. Just enough
/// shape for the loop-bounds helpers to walk; no actual notes (rests are
/// the unified empty-chord representation, which is what the cursor
/// timeline keys via `.rest(RestID)`).
private func makeMeasureScore(measureCount: Int) -> Score {
    let measures = (0 ..< measureCount).map { _ in
        Measure(voices: [Voice(elements: [.rest(duration: .quarter)])])
    }
    let staff = Staff(measures: measures)
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff]
    )
    return Score(division: 480, parts: [part])
}

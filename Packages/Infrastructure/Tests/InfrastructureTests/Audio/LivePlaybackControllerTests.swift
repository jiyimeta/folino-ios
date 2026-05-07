@testable import Audio
import Domain
import Foundation
import SheetMusicAudio
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

    @Test func loopBoundsResolvesToFirstAndLastItemIDsAcrossMeasures() {
        let score = makeMeasureScore(measureCount: 4)
        let range = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        )

        let bounds = LivePlaybackController.loopBounds(for: range, in: score)

        // Each measure in `makeMeasureScore` carries a single quarter-note
        // rest at element index 0. Both endpoints resolve to .rest IDs.
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

    @Test func loopBoundsReturnsNilWhenEndMeasurePastScore() {
        let score = makeMeasureScore(measureCount: 2)
        let range = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0),
            end: ChordPath(systemIndex: 0, measureIndex: 5, voiceIndex: 0, chordIndex: 0)
        )

        #expect(LivePlaybackController.loopBounds(for: range, in: score) == nil)
    }

    @Test func firstScoreItemIDReturnsNoteIDForChordWithNotes() {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)]
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

    @Test func lastScoreItemIDReturnsNilForMeasureWithNoChordElements() {
        let measure = Measure(voices: [Voice(elements: [])])
        let score = makeSingleMeasureScore(measure: measure)

        let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)
        #expect(id == nil)
    }

    // MARK: - Soundfont cache

    @Test func isSoundfontCachedReturnsTrueWhenResolverListsPatch() async {
        let resolver = FakeDomainSoundfontResolver(cached: [
            SoundfontPatchKey(bank: 0, program: 73, isDrums: false),
        ])
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        let cached = await controller.isSoundfontCached(bank: 0, program: 73, isDrums: false)
        let missing = await controller.isSoundfontCached(bank: 8, program: 0, isDrums: false)
        #expect(cached)
        #expect(!missing)
    }

    @Test func isSoundfontCachedReturnsFalseWhenResolverThrows() async {
        let resolver = FakeDomainSoundfontResolver(cachedPatchesError: TestError.boom)
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        let result = await controller.isSoundfontCached(bank: 0, program: 0, isDrums: false)
        #expect(!result)
    }

    @Test func prefetchSoundfontDelegatesToResolver() async throws {
        let resolver = FakeDomainSoundfontResolver()
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        try await controller.prefetchSoundfont(bank: 8, program: 0, isDrums: false)
        let calls = await resolver.resolveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.bank == 8)
        #expect(calls.first?.program == 0)
        #expect(calls.first?.isDrums == false)
    }

    @Test func prefetchSoundfontPropagatesResolverError() async {
        let resolver = FakeDomainSoundfontResolver(resolveError: TestError.boom)
        let controller = LivePlaybackController(
            soundfontResolver: NoopAudioResolver(),
            domainResolver: resolver,
            precisionProbe: StubProbe(available: [])
        )

        await #expect(throws: TestError.boom) {
            try await controller.prefetchSoundfont(bank: 0, program: 0, isDrums: false)
        }
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
/// each containing a single quarter-note rest on voice 0 (rests are
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

/// Builds a single-part, single-staff, single-measure score with the
/// given `Measure`. Used by `firstScoreItemID` / `lastScoreItemID`
/// tests that need to specify exact voice content.
private func makeSingleMeasureScore(measure: Measure) -> Score {
    let staff = Staff(measures: [measure])
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff]
    )
    return Score(division: 480, parts: [part])
}

private enum TestError: Error, Equatable { case boom }

/// Minimal AudioResolver — required by `LivePlaybackController.init` but
/// never consulted by the cache / prefetch paths under test, which only
/// touch the Domain resolver.
private struct NoopAudioResolver: SheetMusicAudio.SoundfontResolver {
    func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    var defaultGMSoundfontURL: URL? { nil }
}

/// Records `resolveSoundfont` calls and returns either a fake URL or the
/// configured error. `cachedPatches()` returns one `SoundfontPatch` per
/// key in `cached`, or throws `cachedPatchesError` if set.
private actor FakeDomainSoundfontResolver: Domain.SoundfontResolver {
    var cached: Set<SoundfontPatchKey>
    var cachedPatchesError: Error?
    var resolveError: Error?
    private(set) var resolveCalls: [(bank: Int, program: Int, isDrums: Bool)] = []

    init(
        cached: Set<SoundfontPatchKey> = [],
        cachedPatchesError: Error? = nil,
        resolveError: Error? = nil
    ) {
        self.cached = cached
        self.cachedPatchesError = cachedPatchesError
        self.resolveError = resolveError
    }

    func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) throws -> URL {
        resolveCalls.append((bank, program, isDrums))
        if let error = resolveError { throw error }
        cached.insert(SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums))
        return URL(fileURLWithPath: "/tmp/sf-\(bank)-\(program)-\(isDrums).sf2")
    }

    func cachedPatches() throws -> [SoundfontPatch] {
        if let error = cachedPatchesError { throw error }
        let now = Date(timeIntervalSince1970: 0)
        return cached.map {
            SoundfontPatch(
                bank: $0.bank, program: $0.program,
                localFileName: "fake.sf2", sizeBytes: 0,
                downloadedAt: now, lastUsedAt: now,
                isBundled: false, isDrums: $0.isDrums
            )
        }
    }

    func totalCacheSizeBytes() throws -> Int64 { 0 }
    func deletePatch(bank _: Int, program _: Int, isDrums _: Bool) throws {}
    func clearCache() throws {}
}

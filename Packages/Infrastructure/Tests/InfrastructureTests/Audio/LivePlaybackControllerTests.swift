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

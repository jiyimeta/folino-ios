@testable import Audio
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore
import Testing

@MainActor
@Suite("LivePlaybackController strips")
struct LivePlaybackControllerStripTests {
    private struct NullResolver: SheetMusicAudio.SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }

    /// One part, one staff, an authored CC 7 of 100/127 and program 40.
    private func score() -> Score {
        Score(
            division: 480,
            parts: [
                Part(
                    id: "P1",
                    trackName: "Violin",
                    instrument: Instrument(
                        id: "violin", longName: "Violin",
                        channels: [InstrumentChannel(program: 40, volume: 100)],
                    ),
                    staves: [Staff(measures: [Measure(voices: [Voice(elements: [])])])],
                ),
            ],
            systemMeasures: [SystemMeasure()],
        )
    }

    private func controller() -> LivePlaybackController {
        LivePlaybackController(soundfontResolver: NullResolver())
    }

    @Test func `reports one strip per part, addressed by ordinal`() throws {
        let controller = controller()
        try controller.load(
            score: score(), displayTitle: nil,
            preferences: PlaybackPreferences(
                scoreItemID: ScoreItemID(), perStrip: [], tempoMultiplier: 1, abRepeat: nil,
            ),
        )

        let strips = controller.mixerStrips()

        #expect(strips.count == 1)
        #expect(strips[0].id == MixerStripID(partIndex: 0, instrumentOrdinal: 0))
        #expect(strips[0].defaultProgram == 40)
        #expect(!strips[0].isDrums)
    }

    /// The snapshot has to be taken BEFORE the saved preferences are seeded. `load` applies them immediately
    /// after preparing, and the engine's own channel list is mutated in place — so reading it afterwards would
    /// report the user's override as the score's level, and the slider's reset target would reset to itself.
    @Test func `reports the score's level even when an override was loaded`() throws {
        let controller = controller()
        let override = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 0.1, gmProgram: 24,
        )
        try controller.load(
            score: score(), displayTitle: nil,
            preferences: PlaybackPreferences(
                scoreItemID: ScoreItemID(), perStrip: [override], tempoMultiplier: 1, abRepeat: nil,
            ),
        )

        let strip = try #require(controller.mixerStrips().first)

        #expect(strip.defaultProgram == 40)
        #expect(abs(strip.defaultVolume - 100.0 / 127.0) < 0.01)
    }

    @Test func `reports nothing once the engine is released`() throws {
        let controller = controller()
        try controller.load(
            score: score(), displayTitle: nil,
            preferences: PlaybackPreferences(
                scoreItemID: ScoreItemID(), perStrip: [], tempoMultiplier: 1, abRepeat: nil,
            ),
        )
        #expect(!controller.mixerStrips().isEmpty)

        controller.releaseEngine()

        #expect(controller.mixerStrips().isEmpty)
    }
}

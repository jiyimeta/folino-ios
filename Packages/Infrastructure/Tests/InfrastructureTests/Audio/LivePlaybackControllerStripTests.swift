@testable import Audio
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore
import Testing

/// Nested in `AudioEngineTests` for its `.serialized` trait: these tests build a real `PlaybackEngine`, which
/// writes the process-wide `AVAudioSession` category at `prepare`.
extension AudioEngineTests {
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
            // The gap this closes: the snapshot alone doesn't prove the override reached the ENGINE at the matching
            // channel — `engine.setVolume(forChannel:)` on the wrong or an unknown channel is a silent no-op, and the
            // snapshot is read before `applyPreferences` writes anything. Read the engine's own live channel list
            // (`@testable import Audio` exposes `controller.engine`, `internal` on `LivePlaybackController`) and check
            // the override actually landed on `.instrument(partIndex: 0, ordinal: 0)`.
            #expect(
                controller.engine.mixerChannels
                    .first { $0.id == .instrument(partIndex: 0, ordinal: 0) }?.volume == 0.1,
            )
        }

        /// Closes the other half of the gap: not just that a loaded override reaches the matching engine channel, but
        /// that the live `setStripVolume(strip:volume:)` path — the one every slider drag calls — moves that SAME
        /// channel afterwards, rather than a channel `MixerStripID` merely happens to look like.
        @Test func `setStripVolume moves the engine channel a loaded override landed on`() throws {
            let controller = controller()
            let strip = MixerStripID(partIndex: 0, instrumentOrdinal: 0)
            try controller.load(
                score: score(), displayTitle: nil,
                preferences: PlaybackPreferences(
                    scoreItemID: ScoreItemID(),
                    perStrip: [StripMixerState(strip: strip, volume: 0.1, gmProgram: nil)],
                    tempoMultiplier: 1, abRepeat: nil,
                ),
            )
            #expect(
                controller.engine.mixerChannels
                    .first { $0.id == .instrument(partIndex: 0, ordinal: 0) }?.volume == 0.1,
            )

            controller.setStripVolume(strip: strip, volume: 0.6)

            #expect(
                controller.engine.mixerChannels
                    .first { $0.id == .instrument(partIndex: 0, ordinal: 0) }?.volume == 0.6,
            )
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
}

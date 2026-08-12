import Domain
@testable import Reader
import SheetMusicCore
import Testing

/// `PlaybackMixerModel` addresses the engine's mixer strips — a (part × distinct instrument) pair — and takes its
/// DEFAULTS from the strip list the engine publishes, never from the score. These pin the two properties that made
/// the staff-addressed model wrong: a part's two instruments are separate sounds, and a slider's reset target is the
/// score's level rather than a copy of whatever the user last set.
@MainActor
struct PlaybackMixerModelStripTests {
    private static let firstStrip = MixerStripID(partIndex: 0, instrumentOrdinal: 0)
    private static let secondStrip = MixerStripID(partIndex: 0, instrumentOrdinal: 1)

    /// Two strips under ONE part — the shape that has no staff-addressed equivalent.
    private static func twoInstrumentPart() -> [MixerStrip] {
        [
            MixerStrip(
                id: firstStrip, partName: "S",
                instrumentName: "ピアノ", defaultVolume: 0.8, defaultProgram: 0, isDrums: false,
            ),
            MixerStrip(
                id: secondStrip, partName: "S",
                instrumentName: "アコーディオン", defaultVolume: 0.8, defaultProgram: 21, isDrums: false,
            ),
        ]
    }

    @Test func `a program override on one strip leaves its sibling alone`() async {
        let controller = FakePlaybackController()
        controller.strips = Self.twoInstrumentPart()
        let model = PlaybackMixerModel()
        // Held in a local: `host` is a weak reference, so a temporary would be gone before `refreshStrips` reads it.
        let host = FakeMixerHost(controller: controller)
        model.host = host
        await model.refreshStrips()

        await model.setProgram(30, for: Self.secondStrip)

        #expect(model.effectiveProgram(for: Self.secondStrip) == 30)
        // The sibling still reports the SCORE's program, not the one just set next door.
        #expect(model.effectiveProgram(for: Self.firstStrip) == 0)
        #expect(controller.stripPrograms.map(\.strip) == [Self.secondStrip])
    }

    @Test func `the slider's reset target is the score's level, not the saved override`() async {
        let controller = FakePlaybackController()
        controller.strips = [
            MixerStrip(
                id: Self.firstStrip, partName: "S",
                instrumentName: "ピアノ", defaultVolume: 0.8, defaultProgram: 0, isDrums: false,
            ),
        ]
        let model = PlaybackMixerModel()
        let host = FakeMixerHost(controller: controller)
        model.host = host
        await model.refreshStrips()

        await model.commitVolume(0.2, for: Self.firstStrip)

        #expect(model.volume(for: Self.firstStrip) == 0.2)
        #expect(model.defaultVolume(for: Self.firstStrip) == 0.8)
    }

    /// Clearing an override sends the engine the strip's OWN default program back — the value the score authored for
    /// that instrument, which for a second instrument under the same part is not the part's opening program.
    @Test func `clearing a program override resends that strip's score program`() async {
        let controller = FakePlaybackController()
        controller.strips = Self.twoInstrumentPart()
        let model = PlaybackMixerModel()
        let host = FakeMixerHost(controller: controller)
        model.host = host
        await model.refreshStrips()

        await model.setProgram(30, for: Self.secondStrip)
        await model.clearProgramOverride(for: Self.secondStrip)

        #expect(!model.hasProgramOverride(for: Self.secondStrip))
        #expect(model.effectiveProgram(for: Self.secondStrip) == 21)
        #expect(controller.stripPrograms.map(\.program) == [30, 21])
    }
}

// MARK: - Fakes

/// The parent surface `PlaybackMixerModel` reads, with no view model behind it. `playbackScore` is deliberately `nil`:
/// nothing in the strip-addressed model consults the score any more, so a mixer works without one.
@MainActor
private final class FakeMixerHost: PlaybackMixerHost {
    let isPlaying = false
    let playbackController: (any PlaybackController)?
    let playbackScore: Score? = nil

    init(controller: any PlaybackController) {
        playbackController = controller
    }
}

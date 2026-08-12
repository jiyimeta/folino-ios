import Domain
import Observation
import SheetMusicCore

/// Surface the mixer needs from its parent. Keeping it a protocol lets the mixer be tested with a hand-written fake
/// host instead of a full `ReaderViewModel`.
@MainActor
protocol PlaybackMixerHost: AnyObject {
    var isPlaying: Bool { get }
    var playbackController: (any PlaybackController)? { get }
    /// The score the engine is actually playing — the natively loaded score, or a PDF's parsed-for-playback score once
    /// its background OMR parse succeeds. The mixer itself no longer reads it (strips and their defaults come from the
    /// engine), but it stays part of the host surface for the rest of the Reader's playback wiring.
    var playbackScore: Score? { get }
}

/// Owns the Reader's playback-mixer surface: per-strip mute / solo / volume and GM program overrides. A strip is a
/// (part × distinct instrument) pair — the unit the engine can control separately — NOT a staff: a grand staff is two
/// staves playing one instrument through one channel, and a part that changes instrument mid-score drives several.
///
/// Both the ADDRESSES and the DEFAULTS come from the engine's published strip list (`refreshStrips()`), never from a
/// score walk: the strip list only exists once a score is prepared, and the engine reports the score's authored level
/// and program as it saw them — before any saved override was seeded — so a reset target can't decay into a copy of
/// the current setting.
///
/// Carved out of `ReaderViewModel` so `PlaybackInspectorScreen` and `ProgramPicker` can receive this model directly
/// without seeing the full view model.
@MainActor
@Observable
final class PlaybackMixerModel {
    /// The prepared engine's strips, in its own order — by part, then by ordinal. Empty until a load lands, because a
    /// mixer describes a prepared engine and there is nothing to draw before one exists.
    private(set) var strips: [MixerStrip] = []
    private(set) var programOverrides: [MixerStripID: Int] = [:]
    private(set) var volumeOverrides: [MixerStripID: Double] = [:]
    private(set) var mutedStrips: Set<MixerStripID> = []
    private(set) var soloStrips: Set<MixerStripID> = []
    /// Transient per-strip volume during a slider drag. Populated by `setVolume`, cleared by `commitVolume`. Lives here
    /// so SwiftUI re-renders the slider as the value moves.
    private(set) var liveVolumes: [MixerStripID: Double] = [:]

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored weak var host: (any PlaybackMixerHost)?

    static let defaultVolume = 1.0

    func sync(from prefs: ReaderPreferences) {
        programOverrides = prefs.stripProgramOverrides
        volumeOverrides = prefs.stripVolumeOverrides
    }

    /// Re-read the engine's strip list. Called after every path that leaves the engine holding a prepared score — both
    /// load paths and a soundfont hot-swap — because that preparation is what produces the strips.
    func refreshStrips() async {
        strips = await host?.playbackController?.mixerStrips() ?? []
    }

    private func strip(_ id: MixerStripID) -> MixerStrip? {
        strips.first { $0.id == id }
    }

    // MARK: - Volume / mute / solo

    func volume(for id: MixerStripID) -> Double {
        liveVolumes[id] ?? volumeOverrides[id] ?? defaultVolume(for: id)
    }

    /// The SCORE's level — the slider's reset target and tick position, independent of any override.
    func defaultVolume(for id: MixerStripID) -> Double {
        strip(id)?.defaultVolume ?? Self.defaultVolume
    }

    func setVolume(_ value: Double, for id: MixerStripID) {
        let clamped = min(max(value, 0), 1)
        liveVolumes[id] = clamped
        Task { [weak self] in
            await self?.host?.playbackController?.setStripVolume(strip: id, volume: clamped)
        }
    }

    /// Slider release: persist the value as the per-score override and clear the transient drag entry. Forwards to the
    /// engine so the post-clamp value is what gets played.
    func commitVolume(_ value: Double, for id: MixerStripID) async {
        let clamped = min(max(value, 0), 1)
        volumeOverrides[id] = clamped
        liveVolumes[id] = nil
        await onChange?()
        await host?.playbackController?.setStripVolume(strip: id, volume: clamped)
    }

    func toggleMute(_ id: MixerStripID) {
        if mutedStrips.contains(id) {
            mutedStrips.remove(id)
        } else {
            mutedStrips.insert(id)
        }
        let isMuted = mutedStrips.contains(id)
        Task { [weak self] in
            await self?.host?.playbackController?.setStripMute(strip: id, isMuted: isMuted)
        }
    }

    func toggleSolo(_ id: MixerStripID) {
        if soloStrips.contains(id) {
            soloStrips.remove(id)
        } else {
            soloStrips.insert(id)
        }
        let isSolo = soloStrips.contains(id)
        Task { [weak self] in
            await self?.host?.playbackController?.setStripSolo(strip: id, isSolo: isSolo)
        }
    }

    // MARK: - Program overrides

    /// Returns the GM program (0…127) currently driving the strip: the user's override if one is set, otherwise the
    /// program the score authored for that strip's instrument.
    func effectiveProgram(for id: MixerStripID) -> Int {
        programOverrides[id] ?? strip(id)?.defaultProgram ?? 0
    }

    func hasProgramOverride(for id: MixerStripID) -> Bool {
        programOverrides[id] != nil
    }

    func setProgram(_ program: Int, for id: MixerStripID) async {
        programOverrides[id] = program
        await onChange?()
        await host?.playbackController?.setStripInstrument(strip: id, program: program)
    }

    func clearProgramOverride(for id: MixerStripID) async {
        programOverrides.removeValue(forKey: id)
        await onChange?()
        await host?.playbackController?.setStripInstrument(
            strip: id,
            program: strip(id)?.defaultProgram ?? 0,
        )
    }
}

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
    /// its background OMR parse succeeds. Reading this (rather than the load state's score) is what lets the mixer
    /// address the staves of a playable PDF.
    var playbackScore: Score? { get }
}

/// Owns the Reader's playback-mixer surface: per-staff mute / solo / volume, plus per-staff and per-part GM program
/// overrides. Carved out of `ReaderViewModel` so `PlaybackInspectorScreen` and `ProgramPicker` can receive this model
/// directly without seeing the full view model.
@MainActor
@Observable
final class PlaybackMixerModel {
    private(set) var staffProgramOverrides: [StaffAddress: Int] = [:]
    private(set) var staffVolumeOverrides: [StaffAddress: Double] = [:]
    private(set) var mutedStaves: Set<StaffAddress> = []
    private(set) var soloStaves: Set<StaffAddress> = []
    /// Transient per-staff volume during a slider drag. Populated by `setVolume`, cleared by `commitVolume`. Lives here
    /// so SwiftUI re-renders the slider as the value moves.
    private(set) var liveStaffVolumes: [StaffAddress: Double] = [:]

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored weak var host: (any PlaybackMixerHost)?

    static let defaultVolume = 1.0

    func sync(from prefs: ReaderPreferences) {
        // re-keyed in Task 9: this model stays staff-addressed until Task 9 converts it; every write elsewhere in
        // this file already synthesizes `instrumentOrdinal: 0` as the part's one strip, so mirror that assumption
        // on the way in — a restored override lands on the part's first staff until the real per-strip UI lands.
        staffProgramOverrides = Dictionary(
            prefs.stripProgramOverrides.compactMap { strip, program in
                strip.instrumentOrdinal == 0
                    ? (StaffAddress(partIndex: strip.partIndex, staffIndexInPart: 0), program) : nil
            },
            uniquingKeysWith: { first, _ in first },
        )
        staffVolumeOverrides = Dictionary(
            prefs.stripVolumeOverrides.compactMap { strip, volume in
                strip.instrumentOrdinal == 0
                    ? (StaffAddress(partIndex: strip.partIndex, staffIndexInPart: 0), volume) : nil
            },
            uniquingKeysWith: { first, _ in first },
        )
    }

    // MARK: - Volume / mute / solo

    func volume(for address: StaffAddress) -> Double {
        liveStaffVolumes[address]
            ?? staffVolumeOverrides[address]
            ?? host?.playbackScore?.initialStaffVolume(at: address)
            ?? Self.defaultVolume
    }

    /// Per-staff baseline used as the slider's reset target and tick position — the score's authored initial volume
    /// when present, otherwise the global default. Independent of any user override.
    func defaultVolume(for address: StaffAddress) -> Double {
        host?.playbackScore?.initialStaffVolume(at: address)
            ?? Self.defaultVolume
    }

    func setVolume(_ value: Double, for address: StaffAddress) {
        let clamped = min(max(value, 0), 1)
        liveStaffVolumes[address] = clamped
        guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
        else { return }
        // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
        let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
        Task { [weak self] in
            await self?.host?.playbackController?.setStripVolume(strip: strip, volume: clamped)
        }
    }

    /// Slider release: persist the value as the per-score override and clear the transient drag entry. Forwards to the
    /// engine so the post-clamp value is what gets played.
    func commitVolume(_ value: Double, for address: StaffAddress) async {
        let clamped = min(max(value, 0), 1)
        staffVolumeOverrides[address] = clamped
        liveStaffVolumes[address] = nil
        await onChange?()
        guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
        else { return }
        // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
        let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
        await host?.playbackController?.setStripVolume(strip: strip, volume: clamped)
    }

    func toggleStaffMute(_ address: StaffAddress) {
        if mutedStaves.contains(address) {
            mutedStaves.remove(address)
        } else {
            mutedStaves.insert(address)
        }
        guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
        else { return }
        let isMuted = mutedStaves.contains(address)
        // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
        let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
        Task { [weak self] in
            await self?.host?.playbackController?.setStripMute(strip: strip, isMuted: isMuted)
        }
    }

    func toggleStaffSolo(_ address: StaffAddress) {
        if soloStaves.contains(address) {
            soloStaves.remove(address)
        } else {
            soloStaves.insert(address)
        }
        guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
        else { return }
        let isSolo = soloStaves.contains(address)
        // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
        let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
        Task { [weak self] in
            await self?.host?.playbackController?.setStripSolo(strip: strip, isSolo: isSolo)
        }
    }

    // MARK: - Per-staff program overrides

    /// Returns the GM program (0…127) currently driving the staff: the user's override if one is set, otherwise the
    /// score's declared instrument program.
    func effectiveProgram(for address: StaffAddress) -> Int {
        if let override = staffProgramOverrides[address] {
            return override
        }
        return host?.playbackScore?.gmProgram(at: address) ?? 0
    }

    func hasProgramOverride(for address: StaffAddress) -> Bool {
        staffProgramOverrides[address] != nil
    }

    func setStaffProgram(_ program: Int, for address: StaffAddress) async {
        staffProgramOverrides[address] = program
        await onChange?()
        guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
        else { return }
        // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
        let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
        await host?.playbackController?.setStripInstrument(strip: strip, program: program)
    }

    func clearStaffProgramOverride(for address: StaffAddress) async {
        staffProgramOverrides.removeValue(forKey: address)
        await onChange?()
        guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
        else { return }
        // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
        let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
        await host?.playbackController?.setStripInstrument(
            strip: strip,
            program: host?.playbackScore?.gmProgram(at: address) ?? 0,
        )
    }

    // MARK: - Per-part program overrides

    /// Effective GM program for a part. All staves under a part share the part's instrument, so we report the first
    /// staff's effective program (or the score default when no override exists).
    func effectiveProgram(forPartIndex partIndex: Int) -> Int {
        let firstAddress = StaffAddress(partIndex: partIndex, staffIndexInPart: 0)
        return effectiveProgram(for: firstAddress)
    }

    func hasProgramOverride(forPartIndex partIndex: Int) -> Bool {
        partStaffAddresses(forPartIndex: partIndex)
            .contains { staffProgramOverrides[$0] != nil }
    }

    /// Set a program override for every staff under the part. Each staff has its own engine voice, so we have to fan
    /// out — but to the user it reads as one "this part's instrument" choice. With the GM soundfont always available
    /// (lightweight bundled or downloaded high-quality preset), no prefetch is needed: every GM program is
    /// immediately playable, so the engine switch is synchronous.
    func setPartProgram(_ program: Int, forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty,
              let score = host?.playbackScore,
              score.parts.indices.contains(partIndex)
        else { return }

        for address in addresses {
            staffProgramOverrides[address] = program
        }
        await onChange?()
        for address in addresses {
            guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
            else { continue }
            // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
            let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
            await host?.playbackController?.setStripInstrument(strip: strip, program: program)
        }
    }

    func clearPartProgramOverride(forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty else { return }
        for address in addresses {
            staffProgramOverrides.removeValue(forKey: address)
        }
        await onChange?()
        for address in addresses {
            guard host?.playbackScore?.flattenedStaffIndex(of: address) != nil
            else { continue }
            // re-keyed in Task 9: strip should be looked up from the score's mixer strips, not synthesized here.
            let strip = MixerStripID(partIndex: address.partIndex, instrumentOrdinal: 0)
            await host?.playbackController?.setStripInstrument(
                strip: strip,
                program: host?.playbackScore?.gmProgram(at: address) ?? 0,
            )
        }
    }

    private func partStaffAddresses(forPartIndex partIndex: Int) -> [StaffAddress] {
        guard let score = host?.playbackScore,
              score.parts.indices.contains(partIndex)
        else { return [] }
        return score.parts[partIndex].staves.indices.map { staffIndex in
            StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
        }
    }
}

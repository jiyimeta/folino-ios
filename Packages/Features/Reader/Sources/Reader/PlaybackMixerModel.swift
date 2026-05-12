import Domain
import Observation
import SheetMusicCore

/// Surface the mixer needs from its parent (transport state + the
/// few playback-control hooks the uncached-soundfont saga drives).
/// Keeping it a protocol lets the mixer be tested with a hand-written
/// fake host instead of a full `ReaderViewModel`.
@MainActor
protocol PlaybackMixerHost: AnyObject {
    var isPlaying: Bool { get }
    var playbackController: (any PlaybackController)? { get }
    var reachability: (any NetworkReachability)? { get }
    var loadState: ReaderViewModel.LoadState { get }
    func pausePlayback() async
    func tryResumePlayback() async
    func setSoundfontAlertKind(_ kind: ReaderViewModel.SoundfontAlertKind?)
}

/// Owns the Reader's playback-mixer surface: per-staff mute / solo /
/// volume, plus per-staff and per-part GM program overrides. Carved out
/// of `ReaderViewModel` so `PlaybackInspectorScreen` and `ProgramPicker`
/// can receive this model directly without seeing the full view model.
///
/// The per-part program path includes a state machine for the case where
/// the chosen instrument isn't cached locally yet (`PendingInstrumentLoad`
/// + `runUncachedPartProgramSwap`) — it pauses playback, surfaces the
/// loading/offline alert via the host, prefetches the soundfont, and
/// resumes on success or reverts on cancel.
@MainActor
@Observable
final class PlaybackMixerModel {
    private(set) var staffProgramOverrides: [StaffAddress: Int] = [:]
    private(set) var staffVolumeOverrides: [StaffAddress: Double] = [:]
    private(set) var mutedStaves: Set<StaffAddress> = []
    private(set) var soloStaves: Set<StaffAddress> = []
    /// Transient per-staff volume during a slider drag. Populated by
    /// `setVolume`, cleared by `commitVolume`. Lives here so SwiftUI
    /// re-renders the slider as the value moves.
    private(set) var liveStaffVolumes: [StaffAddress: Double] = [:]

    @ObservationIgnored private var pendingInstrumentLoad: PendingInstrumentLoad?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored weak var host: (any PlaybackMixerHost)?

    static let defaultVolume = 1.0

    private struct PendingInstrumentLoad {
        let partIndex: Int
        let bank: Int
        let program: Int
        let isDrums: Bool
        /// Per-staff snapshot of the override map restricted to this part
        /// at the moment the pick was registered. `nil` value means "no
        /// override existed for that address; remove on revert".
        let previousOverrides: [(address: StaffAddress, previous: Int?)]
        /// True iff playback was running at the moment we registered the
        /// pick (or was inherited from an earlier in-flight pick that we
        /// just cancelled). Drives auto-resume on success.
        let wasPlaying: Bool
        let task: Task<Void, Error>
    }

    func sync(from prefs: ReaderPreferences) {
        staffProgramOverrides = prefs.staffProgramOverrides
        staffVolumeOverrides = prefs.staffVolumeOverrides
    }

    /// Cancels any in-flight uncached prefetch. Safe to call when nothing
    /// is in flight — the cancel becomes a no-op. Called when the user
    /// dismisses the loading alert.
    func cancelLoadingSoundfonts() {
        pendingInstrumentLoad?.task.cancel()
    }

    /// Awaits an in-flight silent prefetch (one kicked off while playback
    /// was paused). Returns false when the wait was cancelled — callers
    /// should bail out of any in-progress play attempt. No-op fast-path
    /// when there's nothing in flight, or when the prefetch was started
    /// while the user was already playing (in which case the saga itself
    /// handles its own pause/resume).
    func awaitSilentPrefetch() async -> Bool {
        guard let pending = pendingInstrumentLoad, !pending.wasPlaying else {
            return true
        }
        let online = await host?.reachability?.isOnline() ?? true
        host?.setSoundfontAlertKind(online ? .loading : .offline)
        do {
            try await pending.task.value
            host?.setSoundfontAlertKind(nil)
            return true
        } catch {
            host?.setSoundfontAlertKind(nil)
            return false
        }
    }

    // MARK: - Volume / mute / solo

    func volume(for address: StaffAddress) -> Double {
        liveStaffVolumes[address]
            ?? staffVolumeOverrides[address]
            ?? host?.loadState.score?.initialStaffVolume(at: address)
            ?? Self.defaultVolume
    }

    /// Per-staff baseline used as the slider's reset target and tick
    /// position — the score's authored initial volume when present,
    /// otherwise the global default. Independent of any user override.
    func defaultVolume(for address: StaffAddress) -> Double {
        host?.loadState.score?.initialStaffVolume(at: address)
            ?? Self.defaultVolume
    }

    func setVolume(_ value: Double, for address: StaffAddress) {
        let clamped = min(max(value, 0), 1)
        liveStaffVolumes[address] = clamped
        guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
        else { return }
        Task { [weak self] in
            await self?.host?.playbackController?.setStaffVolume(staff: flatIndex, volume: clamped)
        }
    }

    /// Slider release: persist the value as the per-score override and
    /// clear the transient drag entry. Forwards to the engine so the
    /// post-clamp value is what gets played.
    func commitVolume(_ value: Double, for address: StaffAddress) async {
        let clamped = min(max(value, 0), 1)
        staffVolumeOverrides[address] = clamped
        liveStaffVolumes[address] = nil
        await onChange?()
        guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
        else { return }
        await host?.playbackController?.setStaffVolume(staff: flatIndex, volume: clamped)
    }

    func toggleStaffMute(_ address: StaffAddress) {
        if mutedStaves.contains(address) {
            mutedStaves.remove(address)
        } else {
            mutedStaves.insert(address)
        }
        guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
        else { return }
        let isMuted = mutedStaves.contains(address)
        Task { [weak self] in
            await self?.host?.playbackController?.setStaffMute(staff: flatIndex, isMuted: isMuted)
        }
    }

    func toggleStaffSolo(_ address: StaffAddress) {
        if soloStaves.contains(address) {
            soloStaves.remove(address)
        } else {
            soloStaves.insert(address)
        }
        guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
        else { return }
        let isSolo = soloStaves.contains(address)
        Task { [weak self] in
            await self?.host?.playbackController?.setStaffSolo(staff: flatIndex, isSolo: isSolo)
        }
    }

    // MARK: - Per-staff program overrides

    /// Returns the GM program (0…127) currently driving the staff: the user's
    /// override if one is set, otherwise the score's declared instrument program.
    func effectiveProgram(for address: StaffAddress) -> Int {
        if let override = staffProgramOverrides[address] {
            return override
        }
        return host?.loadState.score?.gmProgram(at: address) ?? 0
    }

    func hasProgramOverride(for address: StaffAddress) -> Bool {
        staffProgramOverrides[address] != nil
    }

    func setStaffProgram(_ program: Int, for address: StaffAddress) async {
        staffProgramOverrides[address] = program
        await onChange?()
        guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
        else { return }
        await host?.playbackController?.setStaffInstrument(
            staff: flatIndex,
            bank: host?.loadState.score?.gmBank(at: address) ?? 0,
            program: program,
        )
    }

    func clearStaffProgramOverride(for address: StaffAddress) async {
        staffProgramOverrides.removeValue(forKey: address)
        await onChange?()
        guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
        else { return }
        await host?.playbackController?.setStaffInstrument(
            staff: flatIndex,
            bank: host?.loadState.score?.gmBank(at: address) ?? 0,
            program: host?.loadState.score?.gmProgram(at: address) ?? 0,
        )
    }

    // MARK: - Per-part program overrides

    /// Effective GM program for a part. All staves under a part share the
    /// part's instrument, so we report the first staff's effective program
    /// (or the score default when no override exists).
    func effectiveProgram(forPartIndex partIndex: Int) -> Int {
        let firstAddress = StaffAddress(partIndex: partIndex, staffIndexInPart: 0)
        return effectiveProgram(for: firstAddress)
    }

    func hasProgramOverride(forPartIndex partIndex: Int) -> Bool {
        partStaffAddresses(forPartIndex: partIndex)
            .contains { staffProgramOverrides[$0] != nil }
    }

    /// Set a program override for every staff under the part. Each staff has
    /// its own engine voice, so we have to fan out — but to the user it
    /// reads as one "this part's instrument" choice.
    func setPartProgram(_ program: Int, forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty,
              let score = host?.loadState.score,
              score.parts.indices.contains(partIndex)
        else { return }
        let part = score.parts[partIndex]
        let bank = part.instrument.channel.bank
        let isDrums = part.instrument.useDrumset

        if let controller = host?.playbackController,
           await controller.isSoundfontCached(
               bank: bank, program: program, isDrums: isDrums,
           ) == false
        {
            await runUncachedPartProgramSwap(
                program: program, partIndex: partIndex,
                addresses: addresses, bank: bank, isDrums: isDrums,
                controller: controller,
            )
            return
        }

        // Cache-hit (or no controller): persist the override and fan out.
        for address in addresses {
            staffProgramOverrides[address] = program
        }
        await onChange?()
        for address in addresses {
            guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
            else { continue }
            await host?.playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: host?.loadState.score?.gmBank(at: address) ?? 0,
                program: program,
            )
        }
    }

    private func runUncachedPartProgramSwap(
        program: Int,
        partIndex: Int,
        addresses: [StaffAddress],
        bank: Int,
        isDrums: Bool,
        controller: any PlaybackController,
    ) async {
        // 1. Latest pick wins on the same part: cancel any in-flight pick
        //    and inherit its wasPlaying — without inheritance the new pick
        //    would never auto-resume because the previous one already
        //    paused us.
        var inheritedWasPlaying = false
        if let existing = pendingInstrumentLoad, existing.partIndex == partIndex {
            inheritedWasPlaying = existing.wasPlaying
            existing.task.cancel()
            // Block until the cancelled task's catch branch finishes its
            // revert; otherwise our snapshot below captures the mid-flight
            // state the previous pick mutated to.
            _ = try? await existing.task.value
        }

        let hostWasPlaying = host?.isPlaying ?? false
        let wasPlaying = hostWasPlaying || inheritedWasPlaying
        if hostWasPlaying {
            await host?.pausePlayback()
        }

        let snapshot = addresses.map { address in
            (address: address, previous: staffProgramOverrides[address])
        }
        for address in addresses {
            staffProgramOverrides[address] = program
        }
        await onChange?()

        if wasPlaying {
            let online = await host?.reachability?.isOnline() ?? true
            host?.setSoundfontAlertKind(online ? .loading : .offline)
        }

        let task = Task<Void, Error> {
            try await controller.prefetchSoundfont(
                bank: bank, program: program, isDrums: isDrums,
            )
        }
        let pending = PendingInstrumentLoad(
            partIndex: partIndex, bank: bank, program: program, isDrums: isDrums,
            previousOverrides: snapshot, wasPlaying: wasPlaying, task: task,
        )
        pendingInstrumentLoad = pending

        do {
            try await task.value
            for address in addresses {
                guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
                else { continue }
                await controller.setStaffInstrument(
                    staff: flatIndex, bank: bank, program: program,
                )
            }
            host?.setSoundfontAlertKind(nil)
            if wasPlaying {
                await host?.tryResumePlayback()
            }
        } catch {
            for entry in snapshot {
                if let previous = entry.previous {
                    staffProgramOverrides[entry.address] = previous
                } else {
                    staffProgramOverrides.removeValue(forKey: entry.address)
                }
            }
            await onChange?()
            host?.setSoundfontAlertKind(nil)
            // Only auto-resume on success. Cancel leaves us paused.
        }
        pendingInstrumentLoad = nil
    }

    func clearPartProgramOverride(forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty else { return }
        for address in addresses {
            staffProgramOverrides.removeValue(forKey: address)
        }
        await onChange?()
        for address in addresses {
            guard let flatIndex = host?.loadState.score?.flattenedStaffIndex(of: address)
            else { continue }
            await host?.playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: host?.loadState.score?.gmBank(at: address) ?? 0,
                program: host?.loadState.score?.gmProgram(at: address) ?? 0,
            )
        }
    }

    private func partStaffAddresses(forPartIndex partIndex: Int) -> [StaffAddress] {
        guard let score = host?.loadState.score,
              score.parts.indices.contains(partIndex)
        else { return [] }
        return score.parts[partIndex].staves.indices.map { staffIndex in
            StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
        }
    }
}

// swiftlint:disable file_length
import CoreGraphics
import Domain
import Foundation
import Observation
import SheetMusicCore

@MainActor
@Observable
public final class ReaderViewModel {
    public enum LoadState {
        case loading
        case loaded(Score)
        case failed(message: String)
    }

    /// Which copy the playback-prep alert should show. The view binds
    /// presentation to whether this is non-nil and renders the title
    /// from the case.
    public enum SoundfontAlertKind: Sendable {
        /// Soundfonts are still being prepared and the user pressed
        /// play before the work finished.
        case loading
        /// The device is offline AND the cache doesn't already cover
        /// every voice this score needs — the wait won't make progress
        /// until connectivity is back.
        case offline
    }

    public static let defaultStaffVolume: Double = 1.0

    public private(set) var loadState: LoadState = .loading
    public private(set) var scoreItem: ScoreItem
    public private(set) var preferences: ReaderPreferences
    public private(set) var staffVolumes: [StaffAddress: Double] = [:]
    public private(set) var mutedStaves: Set<StaffAddress> = []
    public private(set) var soloStaves: Set<StaffAddress> = []
    public private(set) var isPlaying: Bool = false
    public private(set) var soundfontAlertKind: SoundfontAlertKind?
    public private(set) var playbackCursor: ScoreCursor?
    public var viewportZoom: CGFloat = 1.0
    public var lastNonUnitZoom: CGFloat = 1.0
    public var isInspectorPresented: Bool = false
    public var layoutMode: LayoutMode = .vertical

    /// Convenience for tests and previews — true while the "loading
    /// playback sounds…" copy is showing.
    public var isLoadingSoundfonts: Bool { soundfontAlertKind == .loading }
    /// Convenience for tests and previews — true while the offline
    /// copy is showing.
    public var isOfflineAlertPresented: Bool { soundfontAlertKind == .offline }

    @ObservationIgnored
    private let repository: any ScoreLibraryRepository
    @ObservationIgnored
    private let gateway: any ScoreFileGateway
    @ObservationIgnored
    private let scoresDirectory: URL
    @ObservationIgnored
    private let defaultStaffSize: CGFloat
    @ObservationIgnored
    private let playbackController: (any PlaybackController)?
    @ObservationIgnored
    private let reachability: (any NetworkReachability)?
    @ObservationIgnored
    private var hasUpdatedLastOpened = false
    @ObservationIgnored
    private var hasLoadedIntoPlayback = false
    @ObservationIgnored
    private var preloadTask: Task<Void, Error>?

    @ObservationIgnored
    private var pendingInstrumentLoad: PendingInstrumentLoad?

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

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        defaultStaffSize: CGFloat = 14,
        playbackController: (any PlaybackController)? = nil,
        reachability: (any NetworkReachability)? = nil
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        self.defaultStaffSize = defaultStaffSize
        self.playbackController = playbackController
        self.reachability = reachability
        preferences = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaves: []
        )
    }

    /// Subscribe to the controller's cursor stream. Must be called from a
    /// view-lifecycle hook (`.task` / `.onAppear`) — NOT from `init` —
    /// so only the VM that SwiftUI actually retains via `@State` registers
    /// its handler. Calling from `init` regressed the playback cursor:
    /// SwiftUI re-evaluates the `@State(wrappedValue:)` expression on
    /// every parent body pass, constructing a fresh VM each time, but
    /// keeps only the first as the persisted state. The subsequent
    /// throwaway VMs all register handlers that capture themselves
    /// weakly, the last one wins, and once it's deallocated the engine's
    /// cursor changes land on a `[weak self]` that's already nil.
    public func startObservingCursor() {
        guard let controller = playbackController else { return }
        controller.observeCursor { [weak self] value in
            self?.playbackCursor = value
        }
    }

    public func load() async {
        loadState = .loading
        let url = scoresDirectory.appending(path: scoreItem.localFileName)
        do {
            let (score, _) = try await gateway.loadScore(fileURL: url)
            await loadOrSeedPreferences()
            loadState = .loaded(score)
            await updateLastOpenedAtOnce()
        } catch {
            let message = describe(error)
            loadState = .failed(message: message)
        }
    }

    public func incrementStaffSize() async {
        let next = min(
            preferences.staffSize + 1,
            ReaderPreferences.maxStaffSize
        )
        await mutatePreferences { $0.staffSize = next }
    }

    public func decrementStaffSize() async {
        let next = max(
            preferences.staffSize - 1,
            ReaderPreferences.minStaffSize
        )
        await mutatePreferences { $0.staffSize = next }
    }

    public func setHonorLayoutBreaks(_ value: Bool) async {
        await mutatePreferences { $0.honorLayoutBreaks = value }
    }

    public func volume(for address: StaffAddress) -> Double {
        staffVolumes[address] ?? Self.defaultStaffVolume
    }

    public func setVolume(_ value: Double, for address: StaffAddress) {
        let clamped = min(max(value, 0), 1)
        staffVolumes[address] = clamped
        guard let flatIndex = flattenedStaffIndex(for: address) else { return }
        Task { await playbackController?.setStaffVolume(staff: flatIndex, volume: clamped) }
    }

    public func toggleStaffMute(address: StaffAddress) {
        if mutedStaves.contains(address) {
            mutedStaves.remove(address)
        } else {
            mutedStaves.insert(address)
        }
        guard let flatIndex = flattenedStaffIndex(for: address) else { return }
        Task {
            await playbackController?.setStaffMute(staff: flatIndex, isMuted: mutedStaves.contains(address))
        }
    }

    public func toggleStaffSolo(address: StaffAddress) {
        if soloStaves.contains(address) {
            soloStaves.remove(address)
        } else {
            soloStaves.insert(address)
        }
        guard let flatIndex = flattenedStaffIndex(for: address) else { return }
        Task {
            await playbackController?.setStaffSolo(staff: flatIndex, isSolo: soloStaves.contains(address))
        }
    }

    /// Returns the GM program (0…127) currently driving the staff: the user's
    /// override if one is set, otherwise the score's declared instrument program.
    public func effectiveProgram(for address: StaffAddress) -> Int {
        if let override = preferences.staffProgramOverrides[address] {
            return override
        }
        return scoreDefaultProgram(for: address) ?? 0
    }

    public func hasProgramOverride(for address: StaffAddress) -> Bool {
        preferences.staffProgramOverrides[address] != nil
    }

    public func setStaffProgram(_ program: Int, for address: StaffAddress) async {
        await mutatePreferences { $0.staffProgramOverrides[address] = program }
        guard let flatIndex = flattenedStaffIndex(for: address) else { return }
        await playbackController?.setStaffInstrument(
            staff: flatIndex,
            bank: scoreDefaultBank(for: address) ?? 0,
            program: program
        )
    }

    public func clearStaffProgramOverride(for address: StaffAddress) async {
        await mutatePreferences { $0.staffProgramOverrides.removeValue(forKey: address) }
        guard let flatIndex = flattenedStaffIndex(for: address) else { return }
        await playbackController?.setStaffInstrument(
            staff: flatIndex,
            bank: scoreDefaultBank(for: address) ?? 0,
            program: scoreDefaultProgram(for: address) ?? 0
        )
    }

    private func scoreDefaultProgram(for address: StaffAddress) -> Int? {
        guard
            case let .loaded(score) = loadState,
            score.parts.indices.contains(address.partIndex)
        else { return nil }
        return score.parts[address.partIndex].instrument.channel.program
    }

    private func scoreDefaultBank(for address: StaffAddress) -> Int? {
        guard
            case let .loaded(score) = loadState,
            score.parts.indices.contains(address.partIndex)
        else { return nil }
        return score.parts[address.partIndex].instrument.channel.bank
    }

    private func flattenedStaffIndex(for address: StaffAddress) -> Int? {
        guard
            case let .loaded(score) = loadState,
            let flatIndex = score.allStaves.firstIndex(where: { $0.address == address })
        else { return nil }

        return flatIndex
    }

    /// Kick off the playback engine's `load` in the background as soon as
    /// the score is open, so the user usually finds soundfonts ready by
    /// the time they tap play. Idempotent — re-entry while a preload is
    /// in flight or already finished is a no-op.
    public func prepareForPlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              !hasLoadedIntoPlayback,
              preloadTask == nil
        else { return }
        let prefs = initialPlaybackPreferences(for: score)
        let task = Task<Void, Error> {
            try await controller.load(score: score, preferences: prefs)
        }
        preloadTask = task
        do {
            // Forward `.task` cancellation (user navigated away mid-prep)
            // into the unstructured load — without this hop the engine
            // load would keep running after the Reader disappears.
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            hasLoadedIntoPlayback = true
        } catch {
            // Cancellation or controller error — leave the slot clear so
            // a subsequent toggle starts a fresh attempt.
        }
        preloadTask = nil
    }

    public func togglePlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              soundfontAlertKind == nil
        else { return }
        if !hasLoadedIntoPlayback {
            let cached = await controller.areSoundfontsAvailableLocally(for: score)
            let online = await reachability?.isOnline() ?? true
            // Pick the alert copy based on what the wait will actually look
            // like to the user:
            //  - cache covers the score → no alert (load is just engine prep)
            //  - offline + cache miss   → "you're offline" (download won't progress)
            //  - online  + cache miss   → "loading playback sounds…"
            if !cached, !online {
                soundfontAlertKind = .offline
            } else if !cached {
                soundfontAlertKind = .loading
            }

            let prefs = initialPlaybackPreferences(for: score)
            let task = preloadTask ?? Task<Void, Error> {
                try await controller.load(score: score, preferences: prefs)
            }
            preloadTask = task
            do {
                try await task.value
                hasLoadedIntoPlayback = true
            } catch {
                soundfontAlertKind = nil
                preloadTask = nil
                return
            }
            soundfontAlertKind = nil
            preloadTask = nil
        }
        if isPlaying {
            await controller.pause()
            isPlaying = false
        } else {
            do {
                try await controller.play()
                isPlaying = true
            } catch {
                isPlaying = false
            }
        }
    }

    /// Cancels an in-flight `load` on the playback controller. Safe to call
    /// when no load is in flight — the cancel is a no-op.
    public func cancelLoadingSoundfonts() {
        preloadTask?.cancel()
        pendingInstrumentLoad?.task.cancel()
    }

    public func toggleStaff(address: StaffAddress) async {
        await mutatePreferences { prefs in
            if prefs.hiddenStaves.contains(address) {
                prefs.hiddenStaves.remove(address)
            } else {
                prefs.hiddenStaves.insert(address)
            }
        }
    }

    public func resetZoom() {
        viewportZoom = 1.0
    }

    /// Records the current zoom as the value to restore on the next
    /// `toggleZoom`. Called from the gesture layer at the end of a pinch.
    public func captureCurrentZoomAsLast() {
        if viewportZoom > 1.0 {
            lastNonUnitZoom = viewportZoom
        }
    }

    public func toggleZoom(targetIfZoomedOut: CGFloat) {
        if viewportZoom > 1.0 {
            resetZoom()
        } else {
            viewportZoom = lastNonUnitZoom > 1.0 ? lastNonUnitZoom : targetIfZoomedOut
        }
    }

    public func setManualCursor(_ cursor: ScoreCursor) {
        playbackCursor = cursor
        guard let controller = playbackController else { return }
        Task { await controller.setCursor(to: cursor) }
    }

    // MARK: - Tempo & metronome

    /// Effective playback rate multiplier — falls back to 1.0 when no
    /// override is set. The InspectorView slider uses this to seed its
    /// local edit state.
    public var effectiveTempoMultiplier: Double { preferences.tempoMultiplier ?? 1.0 }

    /// While the user is dragging the slider: forward the new rate to
    /// the engine immediately for audible feedback. Does NOT persist —
    /// the View calls `commitTempoMultiplier` on slider release.
    public func setTempoMultiplier(_ value: Double) {
        Task { await playbackController?.setTempoMultiplier(value) }
    }

    /// On slider release: persist the override (normalizing 1.0 → nil)
    /// and forward to the engine.
    public func commitTempoMultiplier(_ value: Double) async {
        // Snap "100% to display" back to the no-override state. Slider can stop
        // at e.g. 0.9999999... when visually centred; without this, the override
        // persists as a near-1.0 value the user thought they cleared.
        let normalized: Double? = abs(value - 1.0) < 0.005 ? nil : value
        await mutatePreferences { $0.tempoMultiplier = normalized }
        let effective = preferences.tempoMultiplier ?? 1.0
        await playbackController?.setTempoMultiplier(effective)
    }

    /// Reset to native tempo. Clears the saved override and forwards 1.0.
    public func resetTempoMultiplier() async {
        await mutatePreferences { $0.tempoMultiplier = nil }
        await playbackController?.setTempoMultiplier(1.0)
    }

    /// Forward metronome on/off to the engine. Persistence is owned by
    /// the View layer via @AppStorage("readerMetronomeEnabled") so it
    /// survives across scores.
    public func setMetronomeEnabled(_ enabled: Bool) async {
        await playbackController?.setMetronomeEnabled(enabled)
    }

    // MARK: - Private

    private func initialPlaybackPreferences(for score: Score) -> PlaybackPreferences {
        let states = score.allStaves.enumerated().map { idx, entry in
            let bank = score.parts.indices.contains(entry.address.partIndex)
                ? score.parts[entry.address.partIndex].instrument.channel.bank
                : 0
            let program = preferences.staffProgramOverrides[entry.address]
                ?? (score.parts.indices.contains(entry.address.partIndex)
                    ? score.parts[entry.address.partIndex].instrument.channel.program
                    : 0)
            return StaffMixerState(
                staffIndex: idx,
                volume: staffVolumes[entry.address] ?? Self.defaultStaffVolume,
                isMuted: false,
                isSolo: false,
                gmBank: bank,
                gmProgram: program
            )
        }
        return PlaybackPreferences(
            scoreItemID: scoreItem.id,
            perStaff: states,
            tempoMultiplier: preferences.tempoMultiplier ?? 1.0,
            abRepeat: nil
        )
    }

    private func loadOrSeedPreferences() async {
        do {
            if let stored = try await repository.loadReaderPreferences(for: scoreItem.id) {
                preferences = stored
                return
            }
        } catch {
            // Fall through and seed defaults; persistence error is non-fatal here.
        }
        let seeded = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaves: []
        )
        preferences = seeded
        try? await repository.saveReaderPreferences(seeded)
    }

    private func mutatePreferences(_ apply: (inout ReaderPreferences) -> Void) async {
        var copy = preferences
        apply(&copy)
        // Re-seat through the initializer so clamping rules in
        // `ReaderPreferences.init` always run.
        let normalized = ReaderPreferences(
            id: copy.id,
            scoreItemID: copy.scoreItemID,
            staffSize: copy.staffSize,
            hiddenStaves: copy.hiddenStaves,
            staffProgramOverrides: copy.staffProgramOverrides,
            tempoMultiplier: copy.tempoMultiplier,
            honorLayoutBreaks: copy.honorLayoutBreaks
        )
        preferences = normalized
        try? await repository.saveReaderPreferences(normalized)
    }

    private func updateLastOpenedAtOnce() async {
        guard !hasUpdatedLastOpened else { return }
        hasUpdatedLastOpened = true
        var updated = scoreItem
        updated.lastOpenedAt = Date()
        scoreItem = updated
        try? await repository.saveScoreItem(updated)
    }

    private func describe(_ error: Error) -> String {
        if let domain = error as? DomainError {
            switch domain {
            case .scoreFileNotFound:
                return String(localized: "The score file is missing or unreadable.", bundle: .module)
            case .scoreParseFailed:
                return String(localized: "This file looks corrupted or isn't a valid score.", bundle: .module)
            case .unsupportedFormat:
                return String(localized: "Folino can't open this file type.", bundle: .module)
            default:
                return domain.errorDescription ?? "\(domain)"
            }
        }
        return (error as NSError).localizedDescription
    }
}

extension ReaderViewModel {
    /// Effective GM program for a part. All staves under a part share the
    /// part's instrument, so we report the first staff's effective program
    /// (or the score default when no override exists).
    public func effectiveProgram(forPartIndex partIndex: Int) -> Int {
        let firstAddress = StaffAddress(partIndex: partIndex, staffIndexInPart: 0)
        return effectiveProgram(for: firstAddress)
    }

    public func hasProgramOverride(forPartIndex partIndex: Int) -> Bool {
        partStaffAddresses(forPartIndex: partIndex)
            .contains { preferences.staffProgramOverrides[$0] != nil }
    }

    /// Set a program override for every staff under the part. Each staff has
    /// its own engine voice, so we have to fan out — but to the user it
    /// reads as one "this part's instrument" choice.
    public func setPartProgram(_ program: Int, forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty,
              case let .loaded(score) = loadState,
              score.parts.indices.contains(partIndex)
        else { return }
        let part = score.parts[partIndex]
        let bank = part.instrument.channel.bank
        let isDrums = part.instrument.useDrumset

        if let controller = playbackController,
           await controller.isSoundfontCached(
               bank: bank, program: program, isDrums: isDrums
           ) == false
        {
            await runUncachedPartProgramSwap(
                program: program, partIndex: partIndex,
                addresses: addresses, bank: bank, isDrums: isDrums,
                controller: controller
            )
            return
        }

        // Cache-hit (or no controller): preserve the original synchronous
        // behaviour — persist the override and fan out to the engine.
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }
        for address in addresses {
            guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
            await playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: scoreDefaultBank(for: address) ?? 0,
                program: program
            )
        }
    }

    private func runUncachedPartProgramSwap(
        program: Int,
        partIndex: Int,
        addresses: [StaffAddress],
        bank: Int,
        isDrums: Bool,
        controller: any PlaybackController
    ) async {
        let snapshot = addresses.map { address in
            (address: address, previous: preferences.staffProgramOverrides[address])
        }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }

        let wasPlaying = isPlaying
        if isPlaying {
            await controller.pause()
            isPlaying = false
        }
        if wasPlaying {
            let online = await reachability?.isOnline() ?? true
            soundfontAlertKind = online ? .loading : .offline
        }

        let task = Task<Void, Error> {
            try await controller.prefetchSoundfont(
                bank: bank, program: program, isDrums: isDrums
            )
        }
        let pending = PendingInstrumentLoad(
            partIndex: partIndex, bank: bank, program: program, isDrums: isDrums,
            previousOverrides: snapshot, wasPlaying: wasPlaying, task: task
        )
        pendingInstrumentLoad = pending

        do {
            try await task.value
            for address in addresses {
                guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
                await controller.setStaffInstrument(
                    staff: flatIndex, bank: bank, program: program
                )
            }
            soundfontAlertKind = nil
            if wasPlaying {
                do {
                    try await controller.play()
                    isPlaying = true
                } catch {
                    isPlaying = false
                }
            }
        } catch {
            await mutatePreferences { prefs in
                for entry in snapshot {
                    if let previous = entry.previous {
                        prefs.staffProgramOverrides[entry.address] = previous
                    } else {
                        prefs.staffProgramOverrides.removeValue(forKey: entry.address)
                    }
                }
            }
            soundfontAlertKind = nil
            // Q1 A: only auto-resume on success. Cancel leaves us paused.
        }
        pendingInstrumentLoad = nil
    }

    public func clearPartProgramOverride(forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty else { return }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides.removeValue(forKey: address)
            }
        }
        for address in addresses {
            guard let flatIndex = flattenedStaffIndex(for: address) else { continue }
            await playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: scoreDefaultBank(for: address) ?? 0,
                program: scoreDefaultProgram(for: address) ?? 0
            )
        }
    }

    private func partStaffAddresses(forPartIndex partIndex: Int) -> [StaffAddress] {
        guard
            case let .loaded(score) = loadState,
            score.parts.indices.contains(partIndex)
        else { return [] }
        return score.parts[partIndex].staves.indices.map { staffIndex in
            StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
        }
    }
}

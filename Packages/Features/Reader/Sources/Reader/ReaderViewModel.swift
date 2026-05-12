// swiftlint:disable file_length
import CoreGraphics
import Domain
import Foundation
import Observation
import SheetMusicCore

@MainActor
@Observable
final class ReaderViewModel { // swiftlint:disable:this type_body_length
    enum LoadState {
        case loading
        case loaded(Score)
        case failed(message: String)

        var score: Score? {
            if case let .loaded(score) = self { return score }
            return nil
        }
    }

    /// Which copy the playback-prep alert should show. The view binds
    /// presentation to whether this is non-nil and renders the title
    /// from the case.
    enum SoundfontAlertKind {
        /// Soundfonts are still being prepared and the user pressed
        /// play before the work finished.
        case loading
        /// The device is offline AND the cache doesn't already cover
        /// every voice this score needs — the wait won't make progress
        /// until connectivity is back.
        case offline
    }

    static let defaultStaffVolume = 1.0

    /// Always the same instance (set once at init); declared `var` only so
    /// `@Bindable` projections like `$viewModel.repeatModel.mode` type-check —
    /// the chain needs the intermediate path to be writable.
    var repeatModel = RepeatModel()

    private(set) var loadState: LoadState = .loading
    private(set) var scoreItem: ScoreItem
    private(set) var preferences: ReaderPreferences
    /// Transient per-staff volume during a slider drag. Populated by
    /// `setVolume`, cleared by `commitVolume`. Lives on the VM so SwiftUI
    /// re-renders the slider as the value moves.
    private(set) var liveStaffVolumes: [StaffAddress: Double] = [:]
    private(set) var mutedStaves: Set<StaffAddress> = []
    private(set) var soloStaves: Set<StaffAddress> = []
    private(set) var isPlaying = false
    private(set) var soundfontAlertKind: SoundfontAlertKind?
    private(set) var playbackCursor: ScoreCursor?
    var viewportZoom: CGFloat = 1.0
    var lastNonUnitZoom: CGFloat = 1.0
    var isPlaybackInspectorPresented = false
    var isVisualInspectorPresented = false

    /// Convenience for tests and previews — true while the "loading
    /// playback sounds…" copy is showing.
    var isLoadingSoundfonts: Bool {
        soundfontAlertKind == .loading
    }

    /// Convenience for tests and previews — true while the offline
    /// copy is showing.
    var isOfflineAlertPresented: Bool {
        soundfontAlertKind == .offline
    }

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
    /// Untranslated cursor as the engine published it. Kept so we can
    /// re-derive `playbackCursor` whenever `hiddenStaves` changes — the
    /// engine doesn't know about visibility, so the same raw value can
    /// map to a different visible representation across toggles.
    @ObservationIgnored
    private var rawPlaybackCursor: ScoreCursor?

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

    init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        defaultStaffSize: CGFloat = 14,
        playbackController: (any PlaybackController)? = nil,
        reachability: (any NetworkReachability)? = nil,
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
            hiddenStaves: [],
        )
        wireRepeatModel()
    }

    private func wireRepeatModel() {
        repeatModel.onChange = { [weak self] in
            guard let self else { return }
            await mutatePreferences { prefs in
                prefs.repeatMode = self.repeatModel.mode
                prefs.abRepeat = self.repeatModel.abRange
            }
        }
        repeatModel.scoreProvider = { [weak self] in self?.loadState.score }
        repeatModel.cursorProvider = { [weak self] in self?.playbackCursor }
        repeatModel.controllerProvider = { [weak self] in self?.playbackController }
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
    func startObservingCursor() {
        guard let controller = playbackController else { return }
        controller.observeCursor { [weak self] value in
            guard let self else { return }
            rawPlaybackCursor = value
            playbackCursor = loadState.score?.translateCursorForHiddenStaves(
                value,
                hiddenStaves: preferences.hiddenStaves,
            ) ?? value
            // The engine emits a nil cursor only when playback hits the
            // end of the score (`PlaybackEngine.stop()` clears it; explicit
            // `pause()` does not). Use that signal to flip the toolbar's
            // play/pause glyph back to "play" — without this, isPlaying
            // stays true forever after the score finishes naturally.
            if value == nil, isPlaying {
                isPlaying = false
            }
        }
    }

    func load() async {
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

    func incrementStaffSize() async {
        let next = min(
            preferences.staffSize + 1,
            ReaderPreferences.maxStaffSize,
        )
        await mutatePreferences { $0.staffSize = next }
    }

    func decrementStaffSize() async {
        let next = max(
            preferences.staffSize - 1,
            ReaderPreferences.minStaffSize,
        )
        await mutatePreferences { $0.staffSize = next }
    }

    func setHonorLayoutBreaks(_ value: Bool) async {
        await mutatePreferences { $0.honorLayoutBreaks = value }
    }

    func volume(for address: StaffAddress) -> Double {
        liveStaffVolumes[address]
            ?? preferences.staffVolumeOverrides[address]
            ?? loadState.score?.initialStaffVolume(at: address)
            ?? Self.defaultStaffVolume
    }

    func setVolume(_ value: Double, for address: StaffAddress) {
        let clamped = min(max(value, 0), 1)
        liveStaffVolumes[address] = clamped
        guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { return }
        Task { await playbackController?.setStaffVolume(staff: flatIndex, volume: clamped) }
    }

    /// Slider release: persist the value as the per-score override and
    /// clear the transient drag entry. Forwards to the engine so the
    /// post-clamp value is what gets played.
    func commitVolume(_ value: Double, for address: StaffAddress) async {
        let clamped = min(max(value, 0), 1)
        await mutatePreferences { $0.staffVolumeOverrides[address] = clamped }
        liveStaffVolumes[address] = nil
        guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { return }
        await playbackController?.setStaffVolume(staff: flatIndex, volume: clamped)
    }

    func toggleStaffMute(address: StaffAddress) {
        if mutedStaves.contains(address) {
            mutedStaves.remove(address)
        } else {
            mutedStaves.insert(address)
        }
        guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { return }
        Task {
            await playbackController?.setStaffMute(staff: flatIndex, isMuted: mutedStaves.contains(address))
        }
    }

    func toggleStaffSolo(address: StaffAddress) {
        if soloStaves.contains(address) {
            soloStaves.remove(address)
        } else {
            soloStaves.insert(address)
        }
        guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { return }
        Task {
            await playbackController?.setStaffSolo(staff: flatIndex, isSolo: soloStaves.contains(address))
        }
    }

    /// Returns the GM program (0…127) currently driving the staff: the user's
    /// override if one is set, otherwise the score's declared instrument program.
    func effectiveProgram(for address: StaffAddress) -> Int {
        if let override = preferences.staffProgramOverrides[address] {
            return override
        }
        return loadState.score?.gmProgram(at: address) ?? 0
    }

    func hasProgramOverride(for address: StaffAddress) -> Bool {
        preferences.staffProgramOverrides[address] != nil
    }

    func setStaffProgram(_ program: Int, for address: StaffAddress) async {
        await mutatePreferences { $0.staffProgramOverrides[address] = program }
        guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { return }
        await playbackController?.setStaffInstrument(
            staff: flatIndex,
            bank: loadState.score?.gmBank(at: address) ?? 0,
            program: program,
        )
    }

    func clearStaffProgramOverride(for address: StaffAddress) async {
        await mutatePreferences { $0.staffProgramOverrides.removeValue(forKey: address) }
        guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { return }
        await playbackController?.setStaffInstrument(
            staff: flatIndex,
            bank: loadState.score?.gmBank(at: address) ?? 0,
            program: loadState.score?.gmProgram(at: address) ?? 0,
        )
    }

    /// Returns the rawType the renderer will use for this staff: the
    /// override if one is set, otherwise the score's authored opening
    /// clef (explicit measure-0 clef, else `Staff.defaultClefType`),
    /// falling back to `"G"` if neither exists or the staff isn't in
    /// the score.
    func effectiveClef(for address: StaffAddress) -> String {
        if let override = preferences.staffClefOverrides[address] {
            return override
        }
        return loadState.score?.authoredClef(at: address) ?? "G"
    }

    func hasClefOverride(for address: StaffAddress) -> Bool {
        preferences.staffClefOverrides[address] != nil
    }

    /// True only when an override is set AND its rawType differs from the
    /// score's authored opening clef. The picker uses this to gate the
    /// "Use score's clef" button — when the override happens to match
    /// the authored value (e.g. user picked the same Treble that was
    /// already there) clearing it would be visibly a no-op, so the
    /// reset affordance would just be noise.
    func isClefOverrideEffective(for address: StaffAddress) -> Bool {
        guard let override = preferences.staffClefOverrides[address] else {
            return false
        }
        return override != (loadState.score?.authoredClef(at: address) ?? "G")
    }

    func setClefOverride(_ rawType: String, for address: StaffAddress) async {
        await mutatePreferences { $0.staffClefOverrides[address] = rawType }
    }

    func clearClefOverride(for address: StaffAddress) async {
        await mutatePreferences {
            $0.staffClefOverrides.removeValue(forKey: address)
        }
    }

    /// Kick off the playback engine's `load` in the background as soon as
    /// the score is open, so the user usually finds soundfonts ready by
    /// the time they tap play. Idempotent — re-entry while a preload is
    /// in flight or already finished is a no-op.
    func prepareForPlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              !hasLoadedIntoPlayback,
              preloadTask == nil
        else { return }
        let prefs = PlaybackPreferences.initial(
            for: score,
            readerPreferences: preferences,
            scoreItemID: scoreItem.id,
            defaultVolume: Self.defaultStaffVolume,
        )
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

    func togglePlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              soundfontAlertKind == nil
        else { return }
        if let pending = pendingInstrumentLoad, !pending.wasPlaying {
            // Silent prefetch was kicked off when the user was not playing.
            // Surface the existing alert copy and wait. The prefetch task's
            // own success branch (in setPartProgram) fans setStaffInstrument
            // out; we just need to block until the engine reflects the
            // pick before kicking off play.
            let online = await reachability?.isOnline() ?? true
            soundfontAlertKind = online ? .loading : .offline
            do {
                try await pending.task.value
                soundfontAlertKind = nil
            } catch {
                soundfontAlertKind = nil
                return
            }
        }
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

            let prefs = PlaybackPreferences.initial(
                for: score,
                readerPreferences: preferences,
                scoreItemID: scoreItem.id,
                defaultVolume: Self.defaultStaffVolume,
            )
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
    func cancelLoadingSoundfonts() {
        preloadTask?.cancel()
        pendingInstrumentLoad?.task.cancel()
    }

    func toggleStaff(address: StaffAddress) async {
        await mutatePreferences { prefs in
            if prefs.hiddenStaves.contains(address) {
                prefs.hiddenStaves.remove(address)
            } else {
                prefs.hiddenStaves.insert(address)
            }
        }
        // Re-translate against the new visibility so the cursor recovers
        // immediately when the staff comes back, and falls back to .beat
        // immediately when one is hidden mid-playback.
        playbackCursor = loadState.score?.translateCursorForHiddenStaves(
            rawPlaybackCursor,
            hiddenStaves: preferences.hiddenStaves,
        ) ?? rawPlaybackCursor
    }

    func resetZoom() {
        viewportZoom = 1.0
    }

    /// Records the current zoom as the value to restore on the next
    /// `toggleZoom`. Called from the gesture layer at the end of a pinch.
    func captureCurrentZoomAsLast() {
        if viewportZoom > 1.0 {
            lastNonUnitZoom = viewportZoom
        }
    }

    func toggleZoom(targetIfZoomedOut: CGFloat) {
        if viewportZoom > 1.0 {
            resetZoom()
        } else {
            viewportZoom = lastNonUnitZoom > 1.0 ? lastNonUnitZoom : targetIfZoomedOut
        }
    }

    func setManualCursor(_ cursor: ScoreCursor) {
        let engineCursor = loadState.score?.engineCursorForFilteredTap(
            cursor,
            hiddenStaves: preferences.hiddenStaves,
        ) ?? cursor
        rawPlaybackCursor = engineCursor
        playbackCursor = cursor
        guard let controller = playbackController else { return }
        Task { await controller.setCursor(to: engineCursor) }
    }

    // MARK: - Tempo & metronome

    /// Effective playback rate multiplier — falls back to 1.0 when no
    /// override is set. The InspectorView slider uses this to seed its
    /// local edit state.
    var effectiveTempoMultiplier: Double {
        preferences.tempoMultiplier ?? 1.0
    }

    /// While the user is dragging the slider: forward the new rate to
    /// the engine immediately for audible feedback. Does NOT persist —
    /// the View calls `commitTempoMultiplier` on slider release.
    func setTempoMultiplier(_ value: Double) {
        Task { await playbackController?.setTempoMultiplier(value) }
    }

    /// On slider release: persist the override (normalizing 1.0 → nil)
    /// and forward to the engine.
    func commitTempoMultiplier(_ value: Double) async {
        // Snap "100% to display" back to the no-override state. Slider can stop
        // at e.g. 0.9999999... when visually centred; without this, the override
        // persists as a near-1.0 value the user thought they cleared.
        let normalized: Double? = abs(value - 1.0) < 0.005 ? nil : value
        await mutatePreferences { $0.tempoMultiplier = normalized }
        let effective = preferences.tempoMultiplier ?? 1.0
        await playbackController?.setTempoMultiplier(effective)
    }

    /// Reset to native tempo. Clears the saved override and forwards 1.0.
    func resetTempoMultiplier() async {
        await mutatePreferences { $0.tempoMultiplier = nil }
        await playbackController?.setTempoMultiplier(1.0)
    }

    /// Forward metronome on/off to the engine. Persistence is owned by
    /// the View layer via @AppStorage("readerMetronomeEnabled") so it
    /// survives across scores.
    func setMetronomeEnabled(_ enabled: Bool) async {
        await playbackController?.setMetronomeEnabled(enabled)
    }

    // MARK: - Private

    private func loadOrSeedPreferences() async {
        do {
            if let stored = try await repository.loadReaderPreferences(for: scoreItem.id) {
                preferences = stored
                repeatModel.sync(from: stored)
                return
            }
        } catch {
            // Fall through and seed defaults; persistence error is non-fatal here.
        }
        let seeded = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaves: [],
        )
        preferences = seeded
        repeatModel.sync(from: seeded)
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
            staffVolumeOverrides: copy.staffVolumeOverrides,
            staffClefOverrides: copy.staffClefOverrides,
            tempoMultiplier: copy.tempoMultiplier,
            honorLayoutBreaks: copy.honorLayoutBreaks,
            repeatMode: copy.repeatMode,
            abRepeat: copy.abRepeat,
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
                return String(localized: "reader.error.fileMissing", bundle: .module)
            case .scoreParseFailed:
                return String(localized: "reader.error.corrupted", bundle: .module)
            case .unsupportedFormat:
                return String(localized: "reader.error.cannotOpen.unsupportedType", bundle: .module)
            default:
                return domain.errorDescription ?? "\(domain)"
            }
        }
        return (error as NSError).localizedDescription
    }
}

// MARK: - Part instrument program overrides

extension ReaderViewModel {
    /// Effective GM program for a part. All staves under a part share the
    /// part's instrument, so we report the first staff's effective program
    /// (or the score default when no override exists).
    func effectiveProgram(forPartIndex partIndex: Int) -> Int {
        let firstAddress = StaffAddress(partIndex: partIndex, staffIndexInPart: 0)
        return effectiveProgram(for: firstAddress)
    }

    func hasProgramOverride(forPartIndex partIndex: Int) -> Bool {
        partStaffAddresses(forPartIndex: partIndex)
            .contains { preferences.staffProgramOverrides[$0] != nil }
    }

    /// Set a program override for every staff under the part. Each staff has
    /// its own engine voice, so we have to fan out — but to the user it
    /// reads as one "this part's instrument" choice.
    func setPartProgram(_ program: Int, forPartIndex partIndex: Int) async {
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

        // Cache-hit (or no controller): preserve the original synchronous
        // behaviour — persist the override and fan out to the engine.
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }
        for address in addresses {
            guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { continue }
            await playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: loadState.score?.gmBank(at: address) ?? 0,
                program: program,
            )
        }
    }

    // swiftlint:disable:next function_body_length
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

        let wasPlaying = isPlaying || inheritedWasPlaying
        if isPlaying {
            await controller.pause()
            isPlaying = false
        }

        let snapshot = addresses.map { address in
            (address: address, previous: preferences.staffProgramOverrides[address])
        }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides[address] = program
            }
        }

        if wasPlaying {
            let online = await reachability?.isOnline() ?? true
            soundfontAlertKind = online ? .loading : .offline
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
                guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { continue }
                await controller.setStaffInstrument(
                    staff: flatIndex, bank: bank, program: program,
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

    func clearPartProgramOverride(forPartIndex partIndex: Int) async {
        let addresses = partStaffAddresses(forPartIndex: partIndex)
        guard !addresses.isEmpty else { return }
        await mutatePreferences { prefs in
            for address in addresses {
                prefs.staffProgramOverrides.removeValue(forKey: address)
            }
        }
        for address in addresses {
            guard let flatIndex = loadState.score?.flattenedStaffIndex(of: address) else { continue }
            await playbackController?.setStaffInstrument(
                staff: flatIndex,
                bank: loadState.score?.gmBank(at: address) ?? 0,
                program: loadState.score?.gmProgram(at: address) ?? 0,
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

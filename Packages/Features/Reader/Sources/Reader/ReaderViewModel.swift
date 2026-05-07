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
            guard let self else { return }
            playbackCursor = value
            evaluateLoopWrap(for: value)
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
                await preSeekIfNeeded(controller: controller, score: score)
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

    // MARK: - Repeat / loop

    /// Staged A endpoint not yet committed (incomplete loop).
    private var pendingA: ChordPath?
    /// Staged B endpoint not yet committed (incomplete loop).
    private var pendingB: ChordPath?
    /// True between issuing a wrap-to-A seek and observing the engine
    /// emit a cursor back inside the loop. Suppresses the wrap from
    /// re-firing on the engine's stale past-B cursor emissions, which
    /// would otherwise queue dozens of `play(from:in:)` calls per
    /// second and thrash the AVAudioSequencer into a halt/restart loop.
    @ObservationIgnored
    private var isHandlingLoopWrap: Bool = false

    public var repeatMode: RepeatMode { preferences.repeatMode }
    public var abRepeat: ABRepeatRange? { preferences.abRepeat }
    public var pendingRepeatA: ChordPath? { pendingA ?? preferences.abRepeat?.start }
    public var pendingRepeatB: ChordPath? { pendingB ?? preferences.abRepeat?.end }

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
            abRepeat: preferences.abRepeat
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
            repeatMode: copy.repeatMode,
            abRepeat: copy.abRepeat
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
                return String(localized: "The score file is missing or unreadable.")
            case .scoreParseFailed:
                return String(localized: "This file looks corrupted or isn't a valid score.")
            case .unsupportedFormat:
                return String(localized: "Folino can't open this file type.")
            default:
                return domain.errorDescription ?? "\(domain)"
            }
        }
        return (error as NSError).localizedDescription
    }
}

// MARK: - Repeat / loop mutators

extension ReaderViewModel {
    public func advanceRepeatMode() async {
        let next = preferences.repeatMode.next
        await mutatePreferences { $0.repeatMode = next }
        await forwardLoopRangeToController()
    }

    public func setRepeatA() async {
        guard case let .loaded(score) = loadState,
              let cursor = playbackCursor else { return }
        let measure = measureIndex(of: cursor)
        let head = snapMeasureHead(measureIndex: measure, in: score)
        pendingA = head
        await commitPendingRepeat()
        await forwardLoopRangeToController()
    }

    public func setRepeatB() async {
        guard case let .loaded(score) = loadState,
              let cursor = playbackCursor else { return }
        let measure = measureIndex(of: cursor)
        guard let end = snapMeasureEnd(measureIndex: measure, in: score) else { return }
        pendingB = end
        await commitPendingRepeat()
        await forwardLoopRangeToController()
    }

    public func clearRepeatA() async {
        pendingA = nil
        if let existing = preferences.abRepeat {
            pendingB = existing.end
            await mutatePreferences { $0.abRepeat = nil }
        }
        // Forwards even when no save fired — keeps the controller's last-call
        // cache aligned with the VM's intent (e.g. clearing during .loopAll).
        await forwardLoopRangeToController()
    }

    public func clearRepeatB() async {
        pendingB = nil
        if let existing = preferences.abRepeat {
            pendingA = existing.start
            await mutatePreferences { $0.abRepeat = nil }
        }
        await forwardLoopRangeToController()
    }

    private func activeLoopRange(in score: Score) -> ABRepeatRange? {
        switch preferences.repeatMode {
        case .off: nil
        case .loopAll: scoreFullRange(in: score)
        case .abLoop: preferences.abRepeat
        }
    }

    private func forwardLoopRangeToController() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState else { return }
        await controller.setLoopRange(activeLoopRange(in: score))
    }

    private func evaluateLoopWrap(for cursor: ScoreCursor?) {
        guard isPlaying else {
            // Paused (or never started) — clear suppression so the next
            // playback session re-arms wrap detection.
            isHandlingLoopWrap = false
            return
        }
        guard case let .loaded(score) = loadState,
              let range = activeLoopRange(in: score)
        else {
            // Mode flipped or score unloaded mid-wrap — drop the suppression so
            // the next entry into a loop starts fresh.
            isHandlingLoopWrap = false
            return
        }

        // Re-arm the wrap when we observe a cursor that's actually inside the
        // loop. This is the engine's confirmation that our previous seek landed.
        if let cursor, measureIndex(of: cursor) <= range.end.measureIndex {
            isHandlingLoopWrap = false
        }

        guard !isHandlingLoopWrap else { return }

        // Treat a nil cursor while we believe ourselves to be playing as a
        // natural-end signal: wrap to the loop start.
        if cursor == nil {
            isHandlingLoopWrap = true
            seekToLoopStart(range)
            return
        }
        if let cursor, measureIndex(of: cursor) > range.end.measureIndex {
            isHandlingLoopWrap = true
            seekToLoopStart(range)
        }
    }

    private func preSeekIfNeeded(controller: any PlaybackController, score: Score) async {
        guard let range = activeLoopRange(in: score),
              let cursor = playbackCursor,
              measureIndex(of: cursor) > range.end.measureIndex else { return }
        let target = ScoreCursor.beat(
            measureIndex: range.start.measureIndex, tickInMeasure: 0
        )
        await controller.setCursor(to: target)
        playbackCursor = target
    }

    private func seekToLoopStart(_ range: ABRepeatRange) {
        let startCursor = ScoreCursor.beat(
            measureIndex: range.start.measureIndex, tickInMeasure: 0
        )
        setManualCursor(startCursor)
    }

    private func commitPendingRepeat() async {
        let candidateStart = pendingA ?? preferences.abRepeat?.start
        let candidateEnd = pendingB ?? preferences.abRepeat?.end
        guard let start = candidateStart, let end = candidateEnd else {
            if preferences.abRepeat != nil {
                await mutatePreferences { $0.abRepeat = nil }
            }
            return
        }
        let normalized = normalize(ABRepeatRange(start: start, end: end))
        pendingA = normalized.start
        pendingB = normalized.end
        await mutatePreferences { $0.abRepeat = normalized }
    }
}

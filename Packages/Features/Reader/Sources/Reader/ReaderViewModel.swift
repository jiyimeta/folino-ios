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

    public static let defaultStaffVolume: Double = 1.0

    public private(set) var loadState: LoadState = .loading
    public private(set) var scoreItem: ScoreItem
    public private(set) var preferences: ReaderPreferences
    public private(set) var staffVolumes: [StaffAddress: Double] = [:]
    public private(set) var mutedStaves: Set<StaffAddress> = []
    public private(set) var isPlaying: Bool = false
    public private(set) var isLoadingSoundfonts: Bool = false
    public private(set) var playbackCursor: ScoreCursor?
    public var viewportZoom: CGFloat = 1.0
    public var viewportPan: CGSize = .zero
    public var lastNonUnitZoom: CGFloat = 1.0
    public var isInspectorPresented: Bool = false

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
    private var hasUpdatedLastOpened = false
    @ObservationIgnored
    private var hasLoadedIntoPlayback = false
    @ObservationIgnored
    private var cursorTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadingTask: Task<Void, Error>?

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        defaultStaffSize: CGFloat = 14,
        playbackController: (any PlaybackController)? = nil
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        self.defaultStaffSize = defaultStaffSize
        self.playbackController = playbackController
        preferences = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaves: []
        )
        startObservingCursor()
    }

    deinit {
        cursorTask?.cancel()
    }

    private func startObservingCursor() {
        guard let controller = playbackController else { return }
        cursorTask = Task { [weak self] in
            for await value in controller.cursor {
                guard let self else { return }
                playbackCursor = value
            }
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

    private func flattenedStaffIndex(for address: StaffAddress) -> Int? {
        guard
            case let .loaded(score) = loadState,
            let flatIndex = score.allStaves.firstIndex(where: { $0.address == address })
        else { return nil }

        return flatIndex
    }

    public func togglePlayback() async {
        guard let controller = playbackController,
              case let .loaded(score) = loadState,
              !isLoadingSoundfonts
        else { return }
        if !hasLoadedIntoPlayback {
            let prefs = initialPlaybackPreferences(for: score)
            isLoadingSoundfonts = true
            let task = Task<Void, Error> {
                try await controller.load(score: score, preferences: prefs)
            }
            loadingTask = task
            do {
                try await task.value
                hasLoadedIntoPlayback = true
            } catch {
                isLoadingSoundfonts = false
                loadingTask = nil
                return
            }
            isLoadingSoundfonts = false
            loadingTask = nil
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
        loadingTask?.cancel()
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
        viewportPan = .zero
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

    // MARK: - Private

    private func initialPlaybackPreferences(for score: Score) -> PlaybackPreferences {
        let states = score.allStaves.enumerated().map { idx, entry in
            StaffMixerState(
                staffIndex: idx,
                volume: staffVolumes[entry.address] ?? Self.defaultStaffVolume,
                isMuted: false,
                isSolo: false,
                gmBank: 0,
                gmProgram: 0
            )
        }
        return PlaybackPreferences(
            scoreItemID: scoreItem.id,
            perStaff: states,
            tempoMultiplier: 1.0,
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
            hiddenStaves: copy.hiddenStaves
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

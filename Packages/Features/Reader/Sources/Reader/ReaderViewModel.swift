import CoreGraphics
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class ReaderViewModel {
    public enum LoadState {
        case loading
        case loaded(Score)
        case failed(message: String)
    }

    public private(set) var loadState: LoadState = .loading
    public private(set) var scoreItem: ScoreItem
    public private(set) var preferences: ReaderPreferences
    public var viewportZoom: CGFloat = 1.0
    public var viewportPan: CGSize = .zero
    public var lastNonUnitZoom: CGFloat = 1.0
    public var isChromeVisible: Bool = true
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
    private var hasUpdatedLastOpened = false

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL,
        defaultStaffSize: CGFloat = 14
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        self.defaultStaffSize = defaultStaffSize
        preferences = ReaderPreferences(
            scoreItemID: scoreItem.id,
            staffSize: defaultStaffSize,
            hiddenStaffIDs: []
        )
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

    public func toggleStaff(id: Int) async {
        await mutatePreferences { prefs in
            if prefs.hiddenStaffIDs.contains(id) {
                prefs.hiddenStaffIDs.remove(id)
            } else {
                prefs.hiddenStaffIDs.insert(id)
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

    public func toggleChrome() {
        isChromeVisible.toggle()
    }

    // MARK: - Private

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
            hiddenStaffIDs: []
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
            hiddenStaffIDs: copy.hiddenStaffIDs
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

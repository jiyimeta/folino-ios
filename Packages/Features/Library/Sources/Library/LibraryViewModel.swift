import Domain
import Foundation
import Observation

/// Top-level view model for the Library screen. Owns import state (file picker,
/// duplicate alert, error alert) and the most-recently-imported `ScoreItem`
/// that the view should auto-push into the Reader. Per-list sort/search state
/// lives in `ScoreListViewModel` (one per list view).
@MainActor
@Observable
public final class LibraryViewModel {
    public let repository: any ScoreLibraryRepository
    public let importer: any ScoreFileImporter
    public let gateway: any ScoreFileGateway

    /// The most recent persistence error surfaced through `errorAlertMessage`.
    /// Reset to `nil` when the alert is dismissed.
    public var errorAlertMessage: String?

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
    }

    public func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    public func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    public func setTagIDs(_ tagIDs: Set<TagID>, on scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.tagIDs = tagIDs
        await save(updated)
    }

    func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

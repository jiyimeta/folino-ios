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

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
    }
}

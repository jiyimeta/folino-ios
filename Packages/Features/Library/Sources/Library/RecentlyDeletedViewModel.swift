import Domain
import Foundation
import Observation

/// Drives the Recently Deleted screen. The list is always sorted by `deletedAt` descending — most-recently-trashed on
/// top — and there are no other sort options or search. Source of truth is the repository's `deletedScoreItems`
/// snapshot, which is updated by the same observation task that drives every other Library list, so restores /
/// permanent deletes / soft-deletes propagate automatically.
@MainActor
@Observable
final class RecentlyDeletedViewModel {
    let repository: any ScoreLibraryRepository

    init(repository: any ScoreLibraryRepository) {
        self.repository = repository
    }

    var displayedItems: [ScoreItem] {
        repository.deletedScoreItems.sorted { lhs, rhs in
            (lhs.deletedAt ?? .distantPast) > (rhs.deletedAt ?? .distantPast)
        }
    }
}

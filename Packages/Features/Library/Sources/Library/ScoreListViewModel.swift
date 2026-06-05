import Domain
import Foundation
import Observation

/// Drives any of the three leaf score list views (All / Tag-filtered / Playlist).
@MainActor
@Observable
final class ScoreListViewModel {
    enum Source: Hashable {
        case all
        case favorites
        case taggedWith(TagID)
        case playlist(orderedIDs: [ScoreItemID])
    }

    let source: Source
    let repository: any ScoreLibraryRepository
    var sort: ScoreItemSort
    var searchQuery = ""

    /// `true` when `source == .playlist(...)` and the current sort is the playlist's manual order (i.e. no explicit
    /// sort was picked).
    var isManualOrderActive: Bool {
        if case .playlist = source { return manualOrder }
        return false
    }

    private var manualOrder: Bool

    init(source: Source, repository: any ScoreLibraryRepository) {
        self.source = source
        self.repository = repository
        switch source {
        case .all, .favorites, .taggedWith:
            sort = .dateAddedDesc
            manualOrder = false
        case .playlist:
            sort = .dateAddedDesc // value is ignored while manualOrder is true
            manualOrder = true
        }
    }

    /// Switches off manual order; further reads honour `sort`.
    func selectSort(_ next: ScoreItemSort) {
        sort = next
        manualOrder = false
    }

    /// Returns to the playlist's manual order. Only valid for `.playlist`.
    func selectManualOrder() {
        guard case .playlist = source else { return }
        manualOrder = true
    }

    var displayedItems: [ScoreItem] {
        let scoped = scope(repository.scoreItems)
        let filtered = applySearch(scoped)
        if isManualOrderActive {
            return filtered
        }
        return sort.apply(to: filtered)
    }

    private func scope(_ items: [ScoreItem]) -> [ScoreItem] {
        switch source {
        case .all:
            return items
        case .favorites:
            return items.filter(\.isFavorite)
        case let .taggedWith(tagID):
            return items.filter { $0.tagIDs.contains(tagID) }
        case let .playlist(orderedIDs):
            // Build by ordered IDs to preserve manual order.
            let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return orderedIDs.compactMap { lookup[$0] }
        }
    }

    private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
        items.filter { ScoreSearch.matches(title: $0.title, composer: $0.composer, query: searchQuery) }
    }
}

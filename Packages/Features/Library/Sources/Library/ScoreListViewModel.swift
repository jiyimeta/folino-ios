import Domain
import Foundation
import Observation
import UtilityCore

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
    let analytics: any Analytics
    var sort: ScoreItemSort
    var searchQuery = ""

    /// `true` when `source == .playlist(...)` and the current sort is the playlist's manual order (i.e. no explicit
    /// sort was picked).
    var isManualOrderActive: Bool {
        if case .playlist = source { return manualOrder }
        return false
    }

    private var manualOrder: Bool

    /// Backs the persisted global library sort. Not part of the view-tree state, so it's excluded from observation.
    @ObservationIgnored private let defaults: UserDefaults

    init(
        source: Source,
        repository: any ScoreLibraryRepository,
        analytics: any Analytics = NoopAnalytics(),
        defaults: UserDefaults = .standard,
    ) {
        self.source = source
        self.repository = repository
        self.analytics = analytics
        self.defaults = defaults
        let storedSort = defaults.string(forKey: LibrarySettingsKey.sortOrder)
            .flatMap(ScoreItemSort.init(rawValue:)) ?? .dateAddedDesc
        switch source {
        case .all, .favorites, .taggedWith:
            sort = storedSort
            manualOrder = false
        case .playlist:
            sort = storedSort // value is ignored while manualOrder is true
            manualOrder = true
        }
    }

    /// Switches off manual order; further reads honour `sort`. For non-playlist lists the pick persists as the global
    /// library sort so it survives relaunch; playlists keep their manual order per-playlist and don't write the key.
    func selectSort(_ next: ScoreItemSort) {
        sort = next
        manualOrder = false
        if !isPlaylistSource {
            defaults.set(next.rawValue, forKey: LibrarySettingsKey.sortOrder)
        }
        analytics.log(.sortChanged(next))
    }

    /// Returns to the playlist's manual order. Only valid for `.playlist`.
    func selectManualOrder() {
        guard case .playlist = source else { return }
        manualOrder = true
    }

    private var isPlaylistSource: Bool {
        if case .playlist = source { return true }
        return false
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

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
        /// **macOS only**, in effect — the Mac browser's Recents pane (`MacLibraryBrowser`). Items with a `nil`
        /// `lastOpenedAt` are excluded by `scope(_:)`, matching the same rule `LibrarySourceList.rows` counts by, so
        /// the sidebar's Recents badge and this source's `displayedItems` never disagree.
        case recents
    }

    let source: Source
    let repository: any ScoreLibraryRepository
    let analytics: any Analytics
    var sort: ScoreItemSort
    var searchQuery = ""

    /// `true` when `source == .playlist(...)` and the current sort is the playlist's manual order (i.e. no explicit
    /// sort was picked).
    var isManualOrderActive: Bool {
        if case .playlist = source {
            return manualOrder
        }
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
        case .recents:
            // Always opens ordered by last-opened, regardless of whatever the global library sort happens to be —
            // that sort is `.all`'s business, not Recents'. See `selectSort` for why picking a different sort here
            // doesn't feed back into it either.
            sort = .lastOpenedDesc
            manualOrder = false
        }
    }

    /// Switches off manual order; further reads honour `sort`. For `.all` / `.favorites` / `.taggedWith` the pick
    /// persists as the global library sort so it survives relaunch. Playlists keep their manual order per-playlist
    /// and don't write the key; Recents joins them for a different reason — its default sort is fixed
    /// (`.lastOpenedDesc`, set in `init`), and a sort picked while browsing Recents must not silently change what
    /// `.all` sorts by the next time `AllScoresScreen` reads `LibrarySettingsKey.sortOrder`.
    func selectSort(_ next: ScoreItemSort) {
        sort = next
        manualOrder = false
        if persistsSortSelection {
            defaults.set(next.rawValue, forKey: LibrarySettingsKey.sortOrder)
        }
        analytics.log(.sortChanged(next))
    }

    /// Returns to the playlist's manual order. Only valid for `.playlist`.
    func selectManualOrder() {
        guard case .playlist = source else { return }
        manualOrder = true
    }

    /// `true` for the sources whose sort choice is the shared global library sort — `.playlist` (manual order,
    /// per-playlist) and `.recents` (fixed to `.lastOpenedDesc`) are each excluded for their own reason; see
    /// `selectSort`'s doc comment. Exhaustive on purpose: a future `Source` case must decide this explicitly rather
    /// than inherit `true` from a `default:`.
    private var persistsSortSelection: Bool {
        switch source {
        case .all, .favorites, .taggedWith: true
        case .playlist, .recents: false
        }
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
        case .recents:
            // Same rule `LibrarySourceList.rows` counts the Recents badge by — see `Source.recents`'s doc comment.
            return items.filter { $0.lastOpenedAt != nil }
        }
    }

    private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
        items.filter { ScoreSearch.matches(title: $0.title, composer: $0.composer, query: searchQuery) }
    }
}

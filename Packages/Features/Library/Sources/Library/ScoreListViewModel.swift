import Domain
import Foundation
import Observation

/// Drives any of the three leaf score list views (All / Tag-filtered / Playlist).
@MainActor
@Observable
public final class ScoreListViewModel {
    public enum Source: Hashable, Sendable {
        case all
        case taggedWith(TagID)
        case playlist(orderedIDs: [ScoreItemID])
    }

    public let source: Source
    public let repository: any ScoreLibraryRepository
    public var sort: ScoreItemSort
    public var searchQuery: String = ""

    /// `true` when `source == .playlist(...)` and the current sort is the
    /// playlist's manual order (i.e. no explicit sort was picked).
    public var isManualOrderActive: Bool {
        if case .playlist = source { return manualOrder }
        return false
    }

    private var manualOrder: Bool

    public init(source: Source, repository: any ScoreLibraryRepository) {
        self.source = source
        self.repository = repository
        switch source {
        case .all, .taggedWith:
            sort = .dateAddedDesc
            manualOrder = false
        case .playlist:
            sort = .dateAddedDesc // value is ignored while manualOrder is true
            manualOrder = true
        }
    }

    /// Switches off manual order; further reads honour `sort`.
    public func selectSort(_ next: ScoreItemSort) {
        sort = next
        manualOrder = false
    }

    /// Returns to the playlist's manual order. Only valid for `.playlist`.
    public func selectManualOrder() {
        guard case .playlist = source else { return }
        manualOrder = true
    }

    public var displayedItems: [ScoreItem] {
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
        case let .taggedWith(tagID):
            return items.filter { $0.tagIDs.contains(tagID) }
        case let .playlist(orderedIDs):
            // Build by ordered IDs to preserve manual order.
            let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return orderedIDs.compactMap { lookup[$0] }
        }
    }

    private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.filter { item in
            if item.title.range(of: trimmed, options: opts, locale: .current) != nil {
                return true
            }
            if let composer = item.composer,
               composer.range(of: trimmed, options: opts, locale: .current) != nil
            {
                return true
            }
            return false
        }
    }
}

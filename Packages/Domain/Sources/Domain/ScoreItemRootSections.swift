import Foundation

extension [ScoreItem] {
    /// Top items by `lastOpenedAt` desc. Items with `nil` lastOpenedAt are excluded entirely (they have never been
    /// opened).
    public func mostRecentlyOpened(limit: Int) -> [ScoreItem] {
        guard limit > 0 else { return [] }
        return Array(
            compactMap { item -> (ScoreItem, Date)? in
                guard let lastOpenedAt = item.lastOpenedAt else { return nil }
                return (item, lastOpenedAt)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0),
        )
    }

    /// Favorited items only, ordered by `addedAt` desc, capped at `limit`.
    func favorites(limit: Int) -> [ScoreItem] {
        guard limit > 0 else { return [] }
        return Array(
            filter(\.isFavorite)
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(limit),
        )
    }
}

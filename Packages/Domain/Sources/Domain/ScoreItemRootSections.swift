import Foundation

extension [ScoreItem] {
    /// Items by `lastOpenedAt` desc, capped at `limit`. Passing `nil` (the default) returns every opened item. Items
    /// with `nil` lastOpenedAt are excluded entirely (they have never been opened).
    public func mostRecentlyOpened(limit: Int? = nil) -> [ScoreItem] {
        if let limit, limit <= 0 { return [] }
        let opened = compactMap { item -> (ScoreItem, Date)? in
            guard let lastOpenedAt = item.lastOpenedAt else { return nil }
            return (item, lastOpenedAt)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        guard let limit else { return opened }
        return Array(opened.prefix(limit))
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

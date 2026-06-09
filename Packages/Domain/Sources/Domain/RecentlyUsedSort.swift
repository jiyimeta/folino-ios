import Foundation

/// Minimal projection of a score for recently-used ordering — the only fields the sort helpers read. The Android
/// persistence wire cannot build a full `ScoreItem`, so the shared helpers take this instead.
public struct ScoreOpenInfo: Sendable, Equatable {
    public let id: ScoreItemID
    public let lastOpenedAt: Date?
    public let tagIDs: Set<TagID>

    public init(id: ScoreItemID, lastOpenedAt: Date?, tagIDs: Set<TagID>) {
        self.id = id
        self.lastOpenedAt = lastOpenedAt
        self.tagIDs = tagIDs
    }
}

/// Top-N playlists ordered by the most recent `lastOpenedAt` of any contained score. Empty playlists, or playlists
/// whose every contained ID has no `lastOpenedAt`, fall back to `createdAt`. Ties tiebreak by `name` ascending.
public func playlistsByRecentlyUsed(
    _ playlists: [Playlist],
    openInfo: [ScoreOpenInfo],
    limit: Int,
) -> [Playlist] {
    guard limit > 0 else { return [] }
    let lookup: [ScoreItemID: ScoreOpenInfo] = Dictionary(
        uniqueKeysWithValues: openInfo.map { ($0.id, $0) },
    )
    let keyed: [(Playlist, Date)] = playlists.map { playlist in
        let dates: [Date] = playlist.orderedScoreItemIDs
            .compactMap { lookup[$0]?.lastOpenedAt }
        let key = dates.max() ?? playlist.createdAt
        return (playlist, key)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
    }
    return Array(sorted.prefix(limit).map(\.0))
}

/// Top-N tags ordered by the most recent `lastOpenedAt` across score items carrying the tag. Tags with no items (or no
/// opened items) sink to the bottom and tiebreak by `name` ascending.
public func tagsByRecentlyUsed(
    _ tags: [Tag],
    openInfo: [ScoreOpenInfo],
    limit: Int,
) -> [Tag] {
    guard limit > 0 else { return [] }
    var maxByTag: [TagID: Date] = [:]
    for item in openInfo {
        guard let opened = item.lastOpenedAt else { continue }
        for tagID in item.tagIDs {
            if let existing = maxByTag[tagID], existing >= opened { continue }
            maxByTag[tagID] = opened
        }
    }
    let keyed: [(Tag, Date)] = tags.map { tag in
        (tag, maxByTag[tag.id] ?? .distantPast)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
    }
    return Array(sorted.prefix(limit).map(\.0))
}

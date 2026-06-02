extension Playlist {
    /// Append the IDs not already present, preserving existing order followed by
    /// the new IDs' first-seen order. De-duplicates within `ids` too.
    /// (iOS single-add + `LibraryViewModel.bulkAddToPlaylist` semantics.)
    public mutating func appendUnique(_ ids: [ScoreItemID]) {
        var seen = Set(orderedScoreItemIDs)
        for id in ids where !seen.contains(id) {
            orderedScoreItemIDs.append(id)
            seen.insert(id)
        }
    }

    /// Append if absent, remove if present. (iOS `AddToPlaylistScreen.toggle`.)
    public mutating func toggleMembership(_ id: ScoreItemID) {
        if let idx = orderedScoreItemIDs.firstIndex(of: id) {
            orderedScoreItemIDs.remove(at: idx)
        } else {
            orderedScoreItemIDs.append(id)
        }
    }

    /// Remove the given IDs, preserving the order of the rest.
    /// (iOS `removeFromPlaylist` / `bulkRemoveFromPlaylist`.)
    public mutating func remove(_ ids: Set<ScoreItemID>) {
        orderedScoreItemIDs.removeAll { ids.contains($0) }
    }
}

/// Pure projection of a playlist against the set of currently-live score IDs.
/// Shared by the iOS `PlaylistDetailScreen` / `PlaylistsListScreen` and the
/// Android `LibraryAndroidStore` so both derive identical display data.
public enum PlaylistPresentation {
    /// The playlist's ordered IDs filtered to those still live, order preserved.
    public static func orderedLiveIDs(_ playlist: Playlist, liveIDs: Set<ScoreItemID>) -> [ScoreItemID] {
        playlist.orderedScoreItemIDs.filter { liveIDs.contains($0) }
    }

    /// Count of the playlist's members that are still live.
    public static func liveMemberCount(_ playlist: Playlist, liveIDs: Set<ScoreItemID>) -> Int {
        playlist.orderedScoreItemIDs.reduce(0) { $0 + (liveIDs.contains($1) ? 1 : 0) }
    }
}

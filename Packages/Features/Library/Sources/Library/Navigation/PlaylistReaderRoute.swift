import Domain

/// Navigation value for opening a score **from a playlist**, carrying the originating playlist so the Reader can
/// traverse it (continuous playback). Non-playlist opens keep using the plain `ScoreItem` navigation value, so this is
/// purely additive — it does not change any existing open path.
public struct PlaylistReaderRoute: Hashable, Sendable {
    public let scoreItem: ScoreItem
    public let playlistID: PlaylistID

    public init(scoreItem: ScoreItem, playlistID: PlaylistID) {
        self.scoreItem = scoreItem
        self.playlistID = playlistID
    }
}

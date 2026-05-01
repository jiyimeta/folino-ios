import Foundation

/// Persistence façade for the score library: items, tags, and playlists.
/// Infrastructure provides a SQLite-backed implementation; CloudKit sync
/// observes the same protocol surface so swapping backends is mechanical.
public protocol ScoreLibraryRepository: Sendable {
    func allScoreItems() async throws -> [ScoreItem]
    func scoreItem(id: ScoreItemID) async throws -> ScoreItem?
    func saveScoreItem(_ item: ScoreItem) async throws
    func deleteScoreItem(id: ScoreItemID) async throws

    func allTags() async throws -> [Tag]
    func saveTag(_ tag: Tag) async throws
    func deleteTag(id: TagID) async throws

    func allPlaylists() async throws -> [Playlist]
    func savePlaylist(_ playlist: Playlist) async throws
    func deletePlaylist(id: PlaylistID) async throws
}

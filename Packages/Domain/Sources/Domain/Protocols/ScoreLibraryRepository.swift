import Foundation
import Observation

/// Persistence façade for the score library: items, tags, and playlists.
///
/// The protocol is `@MainActor` and `Observable` so SwiftUI views can read the
/// observed properties directly and re-render when GRDB's `ValueObservation`
/// pushes a new snapshot. The Infrastructure implementation
/// (`LiveScoreLibraryRepository`) starts a long-running observation task on
/// the first `refresh()` call.
@MainActor
public protocol ScoreLibraryRepository: AnyObject, Observable {
    var scoreItems: [ScoreItem] { get }
    var tags: [Tag] { get }
    var playlists: [Playlist] { get }

    /// Initial load. Idempotent — safe to call again to force a re-sync.
    func refresh() async throws

    func saveScoreItem(_ item: ScoreItem) async throws
    func deleteScoreItem(id: ScoreItemID) async throws

    func saveTag(_ tag: Tag) async throws
    func deleteTag(id: TagID) async throws

    func savePlaylist(_ playlist: Playlist) async throws
    func deletePlaylist(id: PlaylistID) async throws

    /// Used by the importer for duplicate detection. Returns every item whose
    /// `contentHash` equals the argument; the caller decides whether to merge.
    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem]
}

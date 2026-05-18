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
    /// Items that are NOT in the trash. Soft-deleted rows (`deletedAt != nil`) are
    /// excluded so every list / search / duplicate-detection consumer hides them
    /// automatically.
    var scoreItems: [ScoreItem] { get }
    /// Items currently in the trash (`deletedAt != nil`). Surfaced only by the
    /// Recently Deleted screen.
    var deletedScoreItems: [ScoreItem] { get }
    var tags: [Tag] { get }
    var playlists: [Playlist] { get }

    /// Initial load. Idempotent — safe to call again to force a re-sync.
    func refresh() async throws

    func saveScoreItem(_ item: ScoreItem) async throws
    /// Soft-delete: stamp `deletedAt = now`. File on disk is preserved.
    /// Equivalent to `softDeleteScoreItem(id:)`; kept as the canonical name so all
    /// existing call sites (row swipe, context menu, bulk) become soft by default.
    func deleteScoreItem(id: ScoreItemID) async throws
    /// Same as `deleteScoreItem(id:)` — explicit name for sites that want to
    /// communicate intent (e.g., the trash screen never calls this, but a future
    /// caller may want to disambiguate from `permanentlyDeleteScoreItem`).
    func softDeleteScoreItem(id: ScoreItemID) async throws
    /// Clear `deletedAt`. The item rejoins `scoreItems` and any tags / playlists
    /// whose ID set still references it.
    func restoreScoreItem(id: ScoreItemID) async throws
    /// Hard delete: drop the row and remove the file on disk.
    func permanentlyDeleteScoreItem(id: ScoreItemID) async throws
    /// Hard-delete every soft-deleted row whose `deletedAt` is strictly older than
    /// the cutoff. Called on app startup and on scene-becomes-active to enforce
    /// the 30-day retention policy.
    func pruneScoreItemsDeleted(before cutoff: Date) async throws

    func saveTag(_ tag: Tag) async throws
    func deleteTag(id: TagID) async throws

    func savePlaylist(_ playlist: Playlist) async throws
    func deletePlaylist(id: PlaylistID) async throws

    /// Used by the importer for duplicate detection. Returns every item whose
    /// `contentHash` equals the argument; the caller decides whether to merge.
    /// Implementations may filter the in-memory observed array or issue a focused
    /// DB query — both are acceptable.
    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem]

    // MARK: - Reader preferences

    /// Returns the persisted Reader display settings for a score, or `nil`
    /// when the score has never been opened. Callers fall back to
    /// device-class defaults on `nil` and persist the chosen defaults via
    /// `saveReaderPreferences(_:)`.
    func loadReaderPreferences(for scoreItemID: ScoreItemID) async throws -> ReaderPreferences?

    /// Persist (insert or update) the Reader display settings for a score.
    /// Errors are mapped to `DomainError.persistenceFailed` by the live
    /// implementation; callers may surface or swallow them.
    func saveReaderPreferences(_ preferences: ReaderPreferences) async throws
}

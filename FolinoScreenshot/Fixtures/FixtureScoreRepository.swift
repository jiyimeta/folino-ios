import Domain
import Foundation
import Observation

/// In-memory `ScoreLibraryRepository` for screenshot scenes. Vends `Fixture.items` so `LibraryViewModel` shows a
/// populated list; every mutation is a no-op (or a trivial in-memory edit) and the auxiliary collections are empty.
///
/// The protocol is `@MainActor`, `AnyObject`, and `Observable`, so this must be a reference type with the `@Observable`
/// macro — a struct cannot satisfy `AnyObject`.
@MainActor
@Observable
final class FixtureScoreRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = Fixture.items
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    /// Optional per-score Reader preferences to vend from `loadReaderPreferences`. Scenes that want the Reader to load
    /// with a specific state (e.g. an active A–B loop region) seed this; the default empty map makes every lookup
    /// return `nil`, so unconfigured scenes (ReaderScene, etc.) keep the seed-defaults path.
    var readerPreferences: [ScoreItemID: ReaderPreferences]

    init(readerPreferences: [ScoreItemID: ReaderPreferences] = [:]) {
        self.readerPreferences = readerPreferences
    }

    func refresh() throws {}

    func saveScoreItem(_ item: ScoreItem) throws {
        if let index = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[index] = item
        }
    }

    func deleteScoreItem(id: ScoreItemID) throws {}
    func softDeleteScoreItem(id: ScoreItemID) throws {}
    func restoreScoreItem(id: ScoreItemID) throws {}
    func permanentlyDeleteScoreItem(id: ScoreItemID) throws {}
    func pruneScoreItemsDeleted(before cutoff: Date) throws {}

    func saveTag(_ tag: Tag) throws {}
    func deleteTag(id: TagID) throws {}

    func savePlaylist(_ playlist: Playlist) throws {}
    func deletePlaylist(id: PlaylistID) throws {}

    func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }

    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        readerPreferences[scoreItemID]
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}
}

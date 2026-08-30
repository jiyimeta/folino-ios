import Domain
import Foundation
import Observation

@MainActor
@Observable
final class FakeScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var deletedScoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    var savedScoreItems: [ScoreItem] = []

    func refresh() throws {}

    func saveScoreItem(_ item: ScoreItem) throws {
        savedScoreItems.append(item)
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
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
        []
    }

    var storedReaderPreferences: [ScoreItemID: ReaderPreferences] = [:]
    var savedReaderPreferences: [ReaderPreferences] = []
    /// When set, `loadReaderPreferences` throws this — the case a caller must tell apart from "no row", since a
    /// failed read must not be answered with a freshly seeded value.
    var loadError: Error?

    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        if let loadError {
            throw loadError
        }
        return storedReaderPreferences[scoreItemID]
    }

    func allReaderPreferences() throws -> [ReaderPreferences] {
        Array(storedReaderPreferences.values)
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {
        savedReaderPreferences.append(preferences)
        storedReaderPreferences[preferences.scoreItemID] = preferences
    }
}

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
    var deletedScoreItemIDs: [ScoreItemID] = []
    var softDeletedScoreItemIDs: [ScoreItemID] = []
    var restoredScoreItemIDs: [ScoreItemID] = []
    var permanentlyDeletedScoreItemIDs: [ScoreItemID] = []
    var prunedCutoffs: [Date] = []
    var savedTags: [Tag] = []
    var deletedTagIDs: [TagID] = []
    var savedPlaylists: [Playlist] = []
    var deletedPlaylistIDs: [PlaylistID] = []
    var refreshCount = 0

    /// If non-nil, `saveScoreItem(_:)` throws this error instead of saving.
    var saveScoreItemError: DomainError?
    /// If non-nil, `deleteScoreItem(id:)` throws this error.
    var deleteScoreItemError: DomainError?
    /// If non-nil, `saveTag(_:)` throws this error instead of saving.
    var saveTagError: DomainError?
    /// If non-nil, `deleteTag(id:)` throws this error.
    var deleteTagError: DomainError?
    /// If non-nil, `savePlaylist(_:)` throws this error instead of saving.
    var savePlaylistError: DomainError?
    /// If non-nil, `deletePlaylist(id:)` throws this error.
    var deletePlaylistError: DomainError?

    func refresh() throws {
        refreshCount += 1
    }

    func saveScoreItem(_ item: ScoreItem) throws {
        if let error = saveScoreItemError { throw error }
        savedScoreItems.append(item)
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }

    func deleteScoreItem(id: ScoreItemID) throws {
        if let error = deleteScoreItemError { throw error }
        deletedScoreItemIDs.append(id)
        try softDeleteScoreItem(id: id)
    }

    func softDeleteScoreItem(id: ScoreItemID) throws {
        if let error = deleteScoreItemError { throw error }
        softDeletedScoreItemIDs.append(id)
        if let idx = scoreItems.firstIndex(where: { $0.id == id }) {
            var item = scoreItems.remove(at: idx)
            item.deletedAt = Date()
            deletedScoreItems.append(item)
        }
    }

    func restoreScoreItem(id: ScoreItemID) throws {
        restoredScoreItemIDs.append(id)
        if let idx = deletedScoreItems.firstIndex(where: { $0.id == id }) {
            var item = deletedScoreItems.remove(at: idx)
            item.deletedAt = nil
            scoreItems.append(item)
        }
    }

    func permanentlyDeleteScoreItem(id: ScoreItemID) throws {
        permanentlyDeletedScoreItemIDs.append(id)
        scoreItems.removeAll { $0.id == id }
        deletedScoreItems.removeAll { $0.id == id }
    }

    func pruneScoreItemsDeleted(before cutoff: Date) throws {
        prunedCutoffs.append(cutoff)
        deletedScoreItems.removeAll { item in
            guard let deletedAt = item.deletedAt else { return false }
            return deletedAt < cutoff
        }
    }

    func saveTag(_ tag: Tag) throws {
        if let error = saveTagError { throw error }
        savedTags.append(tag)
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    func deleteTag(id: TagID) throws {
        if let error = deleteTagError { throw error }
        deletedTagIDs.append(id)
        tags.removeAll { $0.id == id }
        for idx in scoreItems.indices {
            scoreItems[idx].tagIDs.remove(id)
        }
    }

    func savePlaylist(_ playlist: Playlist) throws {
        if let error = savePlaylistError { throw error }
        savedPlaylists.append(playlist)
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    func deletePlaylist(id: PlaylistID) throws {
        if let error = deletePlaylistError { throw error }
        deletedPlaylistIDs.append(id)
        playlists.removeAll { $0.id == id }
    }

    func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }

    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}
}

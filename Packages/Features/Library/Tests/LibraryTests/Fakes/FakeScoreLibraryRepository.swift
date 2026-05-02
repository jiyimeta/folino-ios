import Domain
import Foundation
import Observation

@MainActor
@Observable
final class FakeScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    var savedScoreItems: [ScoreItem] = []
    var deletedScoreItemIDs: [ScoreItemID] = []
    var savedTags: [Tag] = []
    var deletedTagIDs: [TagID] = []
    var savedPlaylists: [Playlist] = []
    var deletedPlaylistIDs: [PlaylistID] = []
    var refreshCount = 0

    /// If non-nil, `saveScoreItem(_:)` throws this error instead of saving.
    var saveScoreItemError: DomainError?
    /// If non-nil, `deleteScoreItem(id:)` throws this error.
    var deleteScoreItemError: DomainError?

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
        scoreItems.removeAll { $0.id == id }
    }

    func saveTag(_ tag: Tag) throws {
        savedTags.append(tag)
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    func deleteTag(id: TagID) throws {
        deletedTagIDs.append(id)
        tags.removeAll { $0.id == id }
        for idx in scoreItems.indices {
            scoreItems[idx].tagIDs.remove(id)
        }
    }

    func savePlaylist(_ playlist: Playlist) throws {
        savedPlaylists.append(playlist)
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    func deletePlaylist(id: PlaylistID) throws {
        deletedPlaylistIDs.append(id)
        playlists.removeAll { $0.id == id }
    }

    func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }
}

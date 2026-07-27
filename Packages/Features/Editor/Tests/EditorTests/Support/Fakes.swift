import Domain
import Foundation
import Observation

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var savedCalls: [(Score, URL, ScoreFormat)] = []

    func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("test")
    }

    func loadScore(fileURL: URL) throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("test")
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        savedCalls.append((score, fileURL, format))
        // Write real bytes so callers that hash the saved file (Task 10's EditorFileFacts) see deterministic content.
        try Data("saved".utf8).write(to: fileURL)
    }
}

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

    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        nil
    }

    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}
}

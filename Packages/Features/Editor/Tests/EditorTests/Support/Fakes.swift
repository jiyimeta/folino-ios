import Domain
import Foundation
import Observation

/// Shared ordered event log two different fakes can append to, so a test can prove ONE fake's call happened before
/// ANOTHER's — something neither fake's own call-recording array can show on its own. `nil` (the default) for every
/// test that doesn't care about cross-fake ordering.
final class FakeEventLog: @unchecked Sendable {
    private(set) var events: [String] = []
    func record(_ event: String) {
        events.append(event)
    }
}

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var savedCalls: [(Score, URL, ScoreFormat)] = []
    var eventLog: FakeEventLog?

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
        eventLog?.record("save")
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

    /// This fake never stores preferences (`loadReaderPreferences` is a `nil` stub), so an empty snapshot is the
    /// honest answer rather than a placeholder.
    func allReaderPreferences() throws -> [ReaderPreferences] {
        []
    }
}

/// Records what the view model asked for and hands back an item stamped as captured, so the save path's ordering
/// can be asserted without touching the file system.
final class FakeScoreOriginalStore: ScoreOriginalStore, @unchecked Sendable {
    var captureCalls: [ScoreItem] = []
    var revertCalls: [(ScoreItem, Bool)] = []
    var eventLog: FakeEventLog?

    func captureOriginalIfNeeded(for item: ScoreItem) throws -> ScoreItem {
        eventLog?.record("capture")
        captureCalls.append(item)
        guard item.originalFileName == nil else { return item }
        return item.capturingOriginal(
            fileName: item.originalSidecarFileName,
            contentHash: "captured-hash",
            provenance: .importTime,
        )
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) throws -> ScoreItem {
        revertCalls.append((item, restoringScoreInfo))
        return item
    }

    func discardOriginal(for item: ScoreItem) throws -> ScoreItem {
        item
    }
}

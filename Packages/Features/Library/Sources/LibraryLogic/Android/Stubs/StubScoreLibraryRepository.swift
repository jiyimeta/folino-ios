#if os(Android)
import Domain
import Foundation
import Observation

/// Stub in-memory repository for the Android JNI pilot. Populated with five sample scores at init.
/// Mutates in-memory for delete/save so all required protocol members work without fatalError.
@MainActor
@Observable
public final class StubScoreLibraryRepository: ScoreLibraryRepository {
    public var scoreItems: [ScoreItem]
    public var deletedScoreItems: [ScoreItem] = []
    public var tags: [Tag] = []
    public var playlists: [Playlist] = []

    private var readerPreferences: [ScoreItemID: ReaderPreferences] = [:]

    public init() {
        scoreItems = Self.makeSampleScores()
    }

    // MARK: - Sample data

    private struct SampleRow {
        let title: String
        let composer: String
        let fileName: String
        let hash: String
        let size: Int64
        let beats: Int
        let bpm: Int
        let key: String
        let hoursOffset: Double
    }

    // swiftlint:disable:next function_body_length
    private static func makeSampleScores() -> [ScoreItem] {
        // Base timestamp for deterministic staggered ordering (each item 1 hour apart).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [SampleRow] = [
            SampleRow(
                title: "Prelude in C major",
                composer: "J. S. Bach",
                fileName: "prelude-c-major.mscx",
                hash: "stub-hash-1",
                size: 1024,
                beats: 32,
                bpm: 80,
                key: "C",
                hoursOffset: -4,
            ),
            SampleRow(
                title: "Fugue in G minor",
                composer: "J. S. Bach",
                fileName: "fugue-g-minor.mscx",
                hash: "stub-hash-2",
                size: 2048,
                beats: 96,
                bpm: 72,
                key: "g",
                hoursOffset: -3,
            ),
            SampleRow(
                title: "Sonata Op. 27 No. 2",
                composer: "L. v. Beethoven",
                fileName: "sonata-op27-no2.mscx",
                hash: "stub-hash-3",
                size: 4096,
                beats: 256,
                bpm: 60,
                key: "c#",
                hoursOffset: -2,
            ),
            SampleRow(
                title: "Etudes Op. 25",
                composer: "F. Chopin",
                fileName: "etudes-op25.mscx",
                hash: "stub-hash-4",
                size: 8192,
                beats: 512,
                bpm: 120,
                key: "Ab",
                hoursOffset: -1,
            ),
            SampleRow(
                title: "Ballade No. 1 Op. 23",
                composer: "F. Chopin",
                fileName: "ballade-no1-op23.mscx",
                hash: "stub-hash-5",
                size: 6144,
                beats: 384,
                bpm: 88,
                key: "g",
                hoursOffset: 0,
            ),
        ]
        return rows.map { row in
            ScoreItem(
                title: row.title,
                composer: row.composer,
                instrumentationSummary: "Piano",
                localFileName: row.fileName,
                contentHash: row.hash,
                sizeBytes: row.size,
                lengthBeats: row.beats,
                defaultTempoBpm: row.bpm,
                primaryKey: row.key,
                addedAt: base.addingTimeInterval(row.hoursOffset * 3600),
                lastOpenedAt: nil,
                tagIDs: [],
                isFavorite: false,
            )
        }
    }

    public func refresh() throws {}

    public func saveScoreItem(_ item: ScoreItem) throws {
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }

    public func deleteScoreItem(id: ScoreItemID) throws {
        if let idx = scoreItems.firstIndex(where: { $0.id == id }) {
            var item = scoreItems.remove(at: idx)
            item.deletedAt = Date()
            deletedScoreItems.append(item)
        }
    }

    public func softDeleteScoreItem(id: ScoreItemID) async throws {
        try await deleteScoreItem(id: id)
    }

    public func restoreScoreItem(id: ScoreItemID) throws {
        if let idx = deletedScoreItems.firstIndex(where: { $0.id == id }) {
            var item = deletedScoreItems.remove(at: idx)
            item.deletedAt = nil
            scoreItems.append(item)
        }
    }

    public func permanentlyDeleteScoreItem(id: ScoreItemID) throws {
        scoreItems.removeAll { $0.id == id }
        deletedScoreItems.removeAll { $0.id == id }
    }

    public func pruneScoreItemsDeleted(before cutoff: Date) throws {
        deletedScoreItems.removeAll { item in
            if let deletedAt = item.deletedAt { return deletedAt < cutoff }
            return false
        }
    }

    public func saveTag(_ tag: Tag) throws {
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    public func deleteTag(id: TagID) throws {
        tags.removeAll { $0.id == id }
    }

    public func savePlaylist(_ playlist: Playlist) throws {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    public func deletePlaylist(id: PlaylistID) throws {
        playlists.removeAll { $0.id == id }
    }

    public func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }

    public func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? {
        readerPreferences[scoreItemID]
    }

    public func saveReaderPreferences(_ preferences: ReaderPreferences) throws {
        readerPreferences[preferences.scoreItemID] = preferences
    }
}
#endif

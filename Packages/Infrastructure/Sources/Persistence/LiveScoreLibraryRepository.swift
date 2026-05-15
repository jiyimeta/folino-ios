import Domain
import Foundation
import GRDB
import Observation

/// Live, GRDB-backed implementation of `ScoreLibraryRepository`. Holds the
/// library snapshot in `@Observable` properties refreshed by a single
/// `ValueObservation` task started on the first `refresh()`.
@MainActor
@Observable
public final class LiveScoreLibraryRepository: ScoreLibraryRepository {
    public private(set) var scoreItems: [ScoreItem] = []
    public private(set) var tags: [Domain.Tag] = []
    public private(set) var playlists: [Playlist] = []

    @ObservationIgnored
    private let database: AppDatabase
    @ObservationIgnored
    private let scoresDirectory: URL
    @ObservationIgnored
    private let playlistsIndexPublisher: (any PlaylistsIndexPublisher)?
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    public init(
        database: AppDatabase,
        scoresDirectory: URL,
        playlistsIndexPublisher: (any PlaylistsIndexPublisher)? = nil,
    ) {
        self.database = database
        self.scoresDirectory = scoresDirectory
        self.playlistsIndexPublisher = playlistsIndexPublisher
    }

    deinit {
        observationTask?.cancel()
    }

    public func refresh() async throws {
        guard observationTask == nil else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            startObservation(firstSnapshotContinuation: cont)
        }
    }

    // MARK: - Observation

    /// Starts the observation task, capturing `firstSnapshotContinuation` so it
    /// is available the moment the first snapshot arrives — no race window.
    private func startObservation(firstSnapshotContinuation cont: CheckedContinuation<Void, Never>) {
        let observation = ValueObservation.tracking { db -> Snapshot in
            let items = try ScoreItemRecord.fetchAll(db)
            let tagsRows = try TagRecord.fetchAll(db)
            let playlistsRows = try PlaylistRecord.fetchAll(db)
            let itemTagRows = try ScoreItemTagRecord.fetchAll(db)
            let playlistItemRows = try PlaylistItemRecord
                .order(Column("playlist_id"), Column("position"))
                .fetchAll(db)
            return Snapshot(
                items: items, tags: tagsRows, playlists: playlistsRows,
                itemTags: itemTagRows, playlistItems: playlistItemRows,
            )
        }

        let pool = database.pool
        // Task.detached so this is NOT @MainActor-isolated — GRDB delivers
        // values on the cooperative thread pool (.task scheduler), and a
        // non-isolated task can freely hop on and off the main actor without
        // being gated on the MainActor queue that refresh() is awaiting on.
        observationTask = Task.detached { [weak self] in
            var resumedOnce = false
            do {
                for try await snap in observation.values(in: pool) {
                    let mapped = Self.materialize(snap)
                    await MainActor.run {
                        guard let self else { return }
                        self.scoreItems = mapped.items
                        self.tags = mapped.tags
                        self.playlists = mapped.playlists
                    }
                    if !resumedOnce {
                        resumedOnce = true
                        cont.resume()
                    }
                }
            } catch {
                // Observation cancelled or DB closed; drop silently.
                if !resumedOnce {
                    resumedOnce = true
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Snapshot translation

    private struct Snapshot {
        var items: [ScoreItemRecord]
        var tags: [TagRecord]
        var playlists: [PlaylistRecord]
        var itemTags: [ScoreItemTagRecord]
        var playlistItems: [PlaylistItemRecord]
    }

    private struct Materialized {
        var items: [ScoreItem]
        var tags: [Domain.Tag]
        var playlists: [Playlist]
    }

    private nonisolated static func materialize(_ snap: Snapshot) -> Materialized {
        var tagIDsByItem: [String: Set<TagID>] = [:]
        for row in snap.itemTags {
            guard let uuid = UUID(uuidString: row.tagID) else { continue }
            tagIDsByItem[row.scoreItemID, default: []].insert(TagID(rawValue: uuid))
        }
        let items: [ScoreItem] = snap.items.compactMap { rec in
            try? rec.toDomain(tagIDs: tagIDsByItem[rec.id] ?? [])
        }
        let tags: [Domain.Tag] = snap.tags.compactMap { try? $0.toDomain() }

        var orderedByPlaylist: [String: [ScoreItemID]] = [:]
        for row in snap.playlistItems {
            guard let uuid = UUID(uuidString: row.scoreItemID) else { continue }
            orderedByPlaylist[row.playlistID, default: []].append(ScoreItemID(rawValue: uuid))
        }
        let playlists: [Playlist] = snap.playlists.compactMap { rec in
            try? rec.toDomain(orderedScoreItemIDs: orderedByPlaylist[rec.id] ?? [])
        }
        return Materialized(items: items, tags: tags, playlists: playlists)
    }

    // MARK: - Stubs (filled in by Tasks 11–13)

    public func saveScoreItem(_ item: ScoreItem) async throws {
        let pool = database.pool
        do {
            try await pool.write { db in
                try ScoreItemRecord(domain: item).save(db)
                // Resync tag relations: drop existing, re-insert.
                try ScoreItemTagRecord
                    .filter(Column("score_item_id") == item.id.rawValue.uuidString)
                    .deleteAll(db)
                for tagID in item.tagIDs {
                    try ScoreItemTagRecord(
                        scoreItemID: item.id.rawValue.uuidString,
                        tagID: tagID.rawValue.uuidString,
                    ).insert(db)
                }
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func deleteScoreItem(id: ScoreItemID) async throws {
        let pool = database.pool
        do {
            // Capture filename for disk cleanup BEFORE the row goes away.
            let filename: String? = try await pool.read { db in
                try ScoreItemRecord.fetchOne(db, key: id.rawValue.uuidString)?.localFileName
            }
            try await pool.write { db in
                _ = try ScoreItemRecord.deleteOne(db, key: id.rawValue.uuidString)
            }
            if let filename {
                let url = scoresDirectory.appending(path: filename)
                // Best-effort: file may already be missing. TODO: log orphaned-file events
                // to telemetry once logging infrastructure exists.
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func saveTag(_ tag: Domain.Tag) async throws {
        do {
            try await database.pool.write { db in
                try TagRecord(domain: tag).save(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func deleteTag(id: TagID) async throws {
        do {
            try await database.pool.write { db in
                _ = try TagRecord.deleteOne(db, key: id.rawValue.uuidString)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func savePlaylist(_ playlist: Playlist) async throws {
        do {
            try await database.pool.write { db in
                try PlaylistRecord(domain: playlist).save(db)
                // Resync the items: drop and reinsert with explicit positions.
                try PlaylistItemRecord
                    .filter(Column("playlist_id") == playlist.id.rawValue.uuidString)
                    .deleteAll(db)
                for (position, scoreItemID) in playlist.orderedScoreItemIDs.enumerated() {
                    try PlaylistItemRecord(
                        playlistID: playlist.id.rawValue.uuidString,
                        scoreItemID: scoreItemID.rawValue.uuidString,
                        position: position,
                    ).insert(db)
                }
            }
            await publishPlaylistsIndexIfNeeded()
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func deletePlaylist(id: PlaylistID) async throws {
        do {
            try await database.pool.write { db in
                _ = try PlaylistRecord.deleteOne(db, key: id.rawValue.uuidString)
            }
            await publishPlaylistsIndexIfNeeded()
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    private func publishPlaylistsIndexIfNeeded() async {
        guard let publisher = playlistsIndexPublisher else { return }
        await publisher.publish(playlists: playlists)
    }

    // MARK: - Reader preferences

    public func loadReaderPreferences(for scoreItemID: ScoreItemID) async throws -> ReaderPreferences? {
        do {
            let key = scoreItemID.rawValue.uuidString
            let record: ReaderPreferencesRecord? = try await database.pool.read { db in
                try ReaderPreferencesRecord
                    .filter(Column("score_item_id") == key)
                    .fetchOne(db)
            }
            return try record?.toDomain()
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func saveReaderPreferences(_ preferences: ReaderPreferences) async throws {
        do {
            try await database.pool.write { db in
                try ReaderPreferencesRecord(domain: preferences).save(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
        do {
            return try await database.pool.read { db in
                let records = try ScoreItemRecord
                    .filter(Column("content_hash") == contentHash)
                    .fetchAll(db)
                return try records.map { rec -> ScoreItem in
                    let tagRows = try ScoreItemTagRecord
                        .filter(Column("score_item_id") == rec.id)
                        .fetchAll(db)
                    let tagIDs = Set(tagRows.compactMap {
                        UUID(uuidString: $0.tagID).map(TagID.init(rawValue:))
                    })
                    return try rec.toDomain(tagIDs: tagIDs)
                }
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }
}

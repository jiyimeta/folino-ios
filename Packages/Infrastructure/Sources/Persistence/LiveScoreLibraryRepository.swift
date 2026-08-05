import Domain
import Foundation
import GRDB
import Observation

/// Live, GRDB-backed implementation of `ScoreLibraryRepository`. Holds the library snapshot in `@Observable` properties
/// refreshed by a single `ValueObservation` task started on the first `refresh()`.
@MainActor
@Observable
public final class LiveScoreLibraryRepository: ScoreLibraryRepository {
    public private(set) var scoreItems: [ScoreItem] = []
    public private(set) var deletedScoreItems: [ScoreItem] = []
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

    /// Starts the observation task, capturing `firstSnapshotContinuation` so it is available the moment the first
    /// snapshot arrives — no race window.
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
        // Task.detached so this is NOT @MainActor-isolated — GRDB delivers values on the cooperative thread pool (.task
        // scheduler), and a non-isolated task can freely hop on and off the main actor without being gated on the
        // MainActor queue that refresh() is awaiting on.
        observationTask = Task.detached { [weak self] in
            var resumedOnce = false
            do {
                for try await snap in observation.values(in: pool) {
                    let mapped = Self.materialize(snap)
                    await MainActor.run {
                        guard let self else { return }
                        self.scoreItems = mapped.items
                        self.deletedScoreItems = mapped.deletedItems
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
        var deletedItems: [ScoreItem]
        var tags: [Domain.Tag]
        var playlists: [Playlist]
    }

    private nonisolated static func materialize(_ snap: Snapshot) -> Materialized {
        var tagIDsByItem: [String: Set<TagID>] = [:]
        for row in snap.itemTags {
            guard let uuid = UUID(uuidString: row.tagID) else { continue }
            tagIDsByItem[row.scoreItemID, default: []].insert(TagID(rawValue: uuid))
        }
        var live: [ScoreItem] = []
        var trashed: [ScoreItem] = []
        for rec in snap.items {
            guard let item = try? rec.toDomain(tagIDs: tagIDsByItem[rec.id] ?? []) else { continue }
            if item.deletedAt == nil {
                live.append(item)
            } else {
                trashed.append(item)
            }
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
        return Materialized(items: live, deletedItems: trashed, tags: tags, playlists: playlists)
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
        try await softDeleteScoreItem(id: id)
    }

    public func softDeleteScoreItem(id: ScoreItemID) async throws {
        do {
            let stamp = Date().timeIntervalSince1970
            try await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE score_items SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                    arguments: [stamp, id.rawValue.uuidString],
                )
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func restoreScoreItem(id: ScoreItemID) async throws {
        do {
            try await database.pool.write { db in
                try db.execute(
                    sql: "UPDATE score_items SET deleted_at = NULL WHERE id = ?",
                    arguments: [id.rawValue.uuidString],
                )
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func permanentlyDeleteScoreItem(id: ScoreItemID) async throws {
        let pool = database.pool
        do {
            // Capture filenames for disk cleanup BEFORE the row goes away.
            let filenames: [String] = try await pool.read { db in
                guard let row = try ScoreItemRecord.fetchOne(db, key: id.rawValue.uuidString) else { return [] }
                return Self.filesBackingRow(row)
            }
            try await pool.write { db in
                _ = try ScoreItemRecord.deleteOne(db, key: id.rawValue.uuidString)
            }
            for filename in filenames {
                let url = scoresDirectory.appending(path: filename)
                // Best-effort: file may already be missing. TODO: log orphaned-file events to telemetry once logging
                // infrastructure exists.
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func pruneScoreItemsDeleted(before cutoff: Date) async throws {
        let pool = database.pool
        do {
            // Drop rows in one write, capture filenames first so we can sweep disk.
            let stamp = cutoff.timeIntervalSince1970
            let filenames: [String] = try await pool.write { db in
                let rows = try ScoreItemRecord
                    .filter(Column("deleted_at") != nil && Column("deleted_at") < stamp)
                    .fetchAll(db)
                let names = rows.flatMap(Self.filesBackingRow)
                for row in rows {
                    _ = try ScoreItemRecord.deleteOne(db, key: row.id)
                }
                return names
            }
            for filename in filenames {
                let url = scoresDirectory.appending(path: filename)
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    /// Every file in the scores directory that belongs to a row. Usually just the score, but an item folino read out
    /// of a PDF also owns the original sidecar — leaving that behind would silently retain the largest file of an
    /// item the user deleted.
    private nonisolated static func filesBackingRow(_ row: ScoreItemRecord) -> [String] {
        var names = [row.localFileName]
        if let sidecar = row.sourcePDFFileName, sidecar != row.localFileName {
            names.append(sidecar)
        }
        return names
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
            await publishPlaylistsIndexIfNeeded(mergingSaved: playlist)
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func deletePlaylist(id: PlaylistID) async throws {
        do {
            try await database.pool.write { db in
                _ = try PlaylistRecord.deleteOne(db, key: id.rawValue.uuidString)
            }
            await publishPlaylistsIndexIfNeeded(mergingDeleted: id)
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    /// Publishes the playlists index to the App Group container.
    ///
    /// `self.playlists` is updated by GRDB's `ValueObservation` on its own schedule, so reading it immediately after a
    /// write returns the pre-mutation snapshot — newly-saved playlists are missing and just-deleted ones still present.
    /// Merge the actual mutation into a local snapshot before publishing so the share-extension index always reflects
    /// what just happened.
    private func publishPlaylistsIndexIfNeeded(
        mergingSaved saved: Playlist? = nil,
        mergingDeleted deletedID: PlaylistID? = nil,
    ) async {
        guard let publisher = playlistsIndexPublisher else { return }
        var snapshot = playlists
        if let saved {
            if let idx = snapshot.firstIndex(where: { $0.id == saved.id }) {
                snapshot[idx] = saved
            } else {
                snapshot.append(saved)
            }
        }
        if let deletedID {
            snapshot.removeAll { $0.id == deletedID }
        }
        await publisher.publish(playlists: snapshot)
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

    public func allReaderPreferences() async throws -> [ReaderPreferences] {
        do {
            let records = try await database.pool.read { db in
                try ReaderPreferencesRecord.fetchAll(db)
            }
            return try records.map { try $0.toDomain() }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
        do {
            return try await database.pool.read { db in
                // Trashed rows are excluded so duplicate detection treats them as gone. The original PDF's hash counts
                // too: once a PDF has been read into notation the row's own `content_hash` is the `.mscz`'s, so
                // matching only that would let the same PDF be imported a second time.
                let records = try ScoreItemRecord
                    .filter(
                        (
                            Column("content_hash") == contentHash
                                || Column("source_pdf_content_hash") == contentHash
                        )
                            && Column("deleted_at") == nil,
                    )
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

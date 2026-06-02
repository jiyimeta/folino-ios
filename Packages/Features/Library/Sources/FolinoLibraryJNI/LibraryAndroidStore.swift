import Domain // ScoreFormat, ScorePresentation
import Foundation
import Observation
import SheetMusicMSCX // MSCZReader.parse(contentsOf:)
import Wirelet
import WireletObservable
import WireletProvided

/// Android-facing Library store. The single screen consumes `scores` as a
/// Kotlin `StateFlow<List<ScoreRowWire>>`; `importScore`/`delete`/`restore`
/// cross the JNI boundary as synchronous methods.
///
/// All persistence *logic* lives here, mirroring the iOS Library: import
/// sequencing, `<id>.mscz` file naming (via Domain `ScoreFormat`), the
/// `deletedAt`-timestamp soft-delete model, and the display projection (via
/// Domain `ScorePresentation`). The injected `LibraryStore` (implemented in
/// Kotlin/Room) is a rule-free backend — it persists the records this store
/// hands it and copies/removes files; it makes no decisions.
///
/// `scores` is a *stored* property reassigned wholesale on every mutation (the
/// Observable bridge's supported `StateFlow` path).
@WireletObservable
@Observable
public final class LibraryAndroidStore {
    @ObservationIgnored private let store: LibraryStore
    public var scores: [ScoreRowWire] = []
    public var deletedScores: [ScoreRowWire] = []

    public var playlists: [PlaylistRowWire] = []
    public var selectedPlaylistItems: [ScoreRowWire] = []
    public var addSheetPlaylists: [PlaylistPickWire] = []

    @ObservationIgnored private var selectedPlaylistID: String?
    @ObservationIgnored private var addSheetScoreID: String?

    public init(store: LibraryStore) {
        self.store = store
        reload() // hydrate from persistence on launch
        reloadPlaylists()
    }

    /// Parse the `.mscz` at `path` (the Kotlin side copies the picked document
    /// into the app cache dir and passes its absolute path), derive the display
    /// fields, copy the file into managed storage as `<id>.mscz`, and persist a
    /// live record. Foundation-only (zlib + XMLParser); unreadable/unparseable
    /// input is ignored (no crash, no row).
    @WireletExpose
    public func importScore(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let score = try? MSCZReader.parse(contentsOf: url) else { return }
        // Shared Domain presenter — identical title/subtitle/composer rules as iOS.
        let fields = ScorePresentation.displayFields(sourceFilename: url.lastPathComponent, score: score)
        let id = UUID().uuidString
        // Shared iOS naming convention: "<id>.<canonicalExtension>".
        let localFileName = "\(id).\(ScoreFormat.mscz.canonicalExtension)"
        store.copyImportedFile(fromPath: path, localFileName: localFileName)
        store.upsert(ScoreRecordWire(
            id: id,
            title: fields.title,
            subtitle: fields.subtitle ?? "",
            composer: fields.composer ?? "",
            localFileName: localFileName,
            deletedAt: 0,
        ))
        reload()
    }

    /// Soft-delete (iOS parity): stamp `deletedAt`, keep the file. The row
    /// disappears from `scores`; `restore` brings it back.
    @WireletExpose
    public func delete(_ id: String) {
        setDeletedAt(id, Date().timeIntervalSince1970)
    }

    /// Undo a soft-delete: clear `deletedAt`.
    @WireletExpose
    public func restore(_ id: String) {
        setDeletedAt(id, 0)
    }

    /// Permanent purge: remove the managed file, then the record (mirrors iOS
    /// `permanentlyDeleteScoreItem`). Unknown id is a no-op.
    @WireletExpose
    public func permanentlyDelete(_ id: String) {
        let all = store.loadAll()
        guard let record = all.first(where: { $0.id == id }) else { return }
        store.removeFile(localFileName: record.localFileName)
        store.deleteRecord(id: id)
        // Project from the local snapshot minus the purged row — no second loadAll().
        reload(using: all.filter { $0.id != id })
        reloadPlaylists()
    }

    /// Bulk restore: clear `deletedAt` for each id, then reload once (mirrors
    /// `LibraryViewModel.bulkRestore` semantics on iOS). Unknown ids are skipped.
    @WireletExpose
    public func restoreMany(_ ids: [String]) {
        var all = store.loadAll()
        for id in ids {
            guard let idx = all.firstIndex(where: { $0.id == id }) else { continue }
            all[idx].deletedAt = 0
            store.upsert(all[idx])
        }
        reload(using: all)
        reloadPlaylists()
    }

    /// Bulk permanent purge (mirrors `LibraryViewModel.bulkPermanentlyDelete`):
    /// remove file + record for each id, then reload once.
    @WireletExpose
    public func permanentlyDeleteMany(_ ids: [String]) {
        let idSet = Set(ids)
        let all = store.loadAll()
        for record in all where idSet.contains(record.id) {
            store.removeFile(localFileName: record.localFileName)
            store.deleteRecord(id: record.id)
        }
        // Project from the local snapshot minus the purged rows — no second loadAll().
        reload(using: all.filter { !idSet.contains($0.id) })
        reloadPlaylists()
    }

    private func setDeletedAt(_ id: String, _ stamp: Double) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].deletedAt = stamp
        store.upsert(all[idx])
        reload(using: all)
        reloadPlaylists()
    }

    /// Rebuild the displayed lists: live records (`deletedAt <= 0`) in `scores`
    /// and soft-deleted records (most-recently-trashed first) in `deletedScores`,
    /// both projected to the display wire type. Pass `records` to reuse an
    /// already-loaded snapshot and avoid a second backend read.
    private func reload(using records: [ScoreRecordWire]? = nil) {
        let all = records ?? store.loadAll()
        scores = all
            .filter { $0.deletedAt <= 0 }
            .map(Self.row)
        // Recently Deleted: soft-deleted rows, most-recently-trashed first
        // (mirrors iOS RecentlyDeletedViewModel). Sorting happens here, before
        // projection, so ScoreRowWire need not carry deletedAt.
        deletedScores = all
            .filter { $0.deletedAt > 0 }
            .sorted { $0.deletedAt > $1.deletedAt }
            .map(Self.row)
    }

    private static func row(_ record: ScoreRecordWire) -> ScoreRowWire {
        ScoreRowWire(id: record.id, title: record.title, subtitle: record.subtitle, composer: record.composer)
    }

    // MARK: - Playlists

    @WireletExpose
    public func beginAddToPlaylist(_ scoreId: String) {
        addSheetScoreID = scoreId
        refreshAddSheet(domain: loadDomainPlaylists())
    }

    @WireletExpose
    public func beginBulkAddToPlaylist() {
        addSheetScoreID = nil
        refreshAddSheet(domain: loadDomainPlaylists())
    }

    /// Bulk soft-delete (All Scores CAB "Delete"); mirrors iOS `bulkDelete`.
    @WireletExpose
    public func deleteMany(_ ids: [String]) {
        let now = Date().timeIntervalSince1970
        var all = store.loadAll()
        let idSet = Set(ids)
        for idx in all.indices where idSet.contains(all[idx].id) {
            all[idx].deletedAt = now
            store.upsert(all[idx])
        }
        reload(using: all)
        reloadPlaylists()
    }

    private func scoreItemID(_ raw: String) -> ScoreItemID? {
        UUID(uuidString: raw).map(ScoreItemID.init(rawValue:))
    }

    /// Set of live (`deletedAt <= 0`) score IDs, for membership projection.
    private func liveScoreIDs(_ records: [ScoreRecordWire]) -> Set<ScoreItemID> {
        Set(records.filter { $0.deletedAt <= 0 }.compactMap { scoreItemID($0.id) })
    }

    /// Build Domain `Playlist` values from the backend's record + item rows
    /// (items already ordered by position), mirroring iOS materialization.
    private func loadDomainPlaylists() -> [Playlist] {
        let items = store.loadPlaylistItems()
        var idsByPlaylist: [String: [ScoreItemID]] = [:]
        for item in items {
            guard let sid = scoreItemID(item.scoreItemId) else { continue }
            idsByPlaylist[item.playlistId, default: []].append(sid)
        }
        return store.loadPlaylists().compactMap { rec in
            guard let uuid = UUID(uuidString: rec.id) else { return nil }
            return Playlist(
                id: PlaylistID(rawValue: uuid),
                name: rec.name,
                orderedScoreItemIDs: idsByPlaylist[rec.id] ?? [],
                createdAt: Date(timeIntervalSince1970: rec.createdAt),
            )
        }
    }

    private func domainPlaylist(_ id: String) -> Playlist? {
        loadDomainPlaylists().first { $0.id.rawValue.uuidString == id }
    }

    /// Persist a playlist: upsert its row, then drop + reinsert its membership
    /// with explicit positions (iOS `savePlaylist` parity).
    private func persist(_ playlist: Playlist) {
        let pid = playlist.id.rawValue.uuidString
        store.upsertPlaylist(PlaylistRecordWire(
            id: pid,
            name: playlist.name,
            createdAt: playlist.createdAt.timeIntervalSince1970,
        ))
        let items = playlist.orderedScoreItemIDs.enumerated().map { offset, id in
            PlaylistItemWire(playlistId: pid, scoreItemId: id.rawValue.uuidString, position: Int32(offset))
        }
        store.replacePlaylistItems(pid, items)
    }

    /// Recompute every playlist-derived observable from one backend snapshot.
    private func reloadPlaylists() {
        let domain = loadDomainPlaylists()
        let records = store.loadAll()
        let liveIDs = liveScoreIDs(records)

        playlists = domain
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                PlaylistRowWire(
                    id: $0.id.rawValue.uuidString,
                    name: $0.name,
                    memberCount: Int32(PlaylistPresentation.liveMemberCount($0, liveIDs: liveIDs)),
                )
            }

        recomputeSelectedItems(domain: domain, records: records, liveIDs: liveIDs)
        refreshAddSheet(domain: domain)
    }

    private func recomputeSelectedItems(domain: [Playlist], records: [ScoreRecordWire], liveIDs: Set<ScoreItemID>) {
        guard let sel = selectedPlaylistID,
              let playlist = domain.first(where: { $0.id.rawValue.uuidString == sel })
        else {
            selectedPlaylistItems = []
            return
        }
        var rowByID: [ScoreItemID: ScoreRowWire] = [:]
        for record in records where record.deletedAt <= 0 {
            if let sid = scoreItemID(record.id) { rowByID[sid] = Self.row(record) }
        }
        selectedPlaylistItems = PlaylistPresentation
            .orderedLiveIDs(playlist, liveIDs: liveIDs)
            .compactMap { rowByID[$0] }
    }

    private func refreshAddSheet(domain: [Playlist]) {
        let focus = addSheetScoreID.flatMap(scoreItemID)
        addSheetPlaylists = domain
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                PlaylistPickWire(
                    id: $0.id.rawValue.uuidString,
                    name: $0.name,
                    contains: focus.map($0.orderedScoreItemIDs.contains) ?? false,
                )
            }
    }

    @WireletExpose
    public func addToPlaylist(_ scoreId: String, _ playlistId: String) {
        guard let sid = scoreItemID(scoreId), var playlist = domainPlaylist(playlistId) else { return }
        playlist.appendUnique([sid])
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func removeFromPlaylist(_ scoreId: String, _ playlistId: String) {
        guard let sid = scoreItemID(scoreId), var playlist = domainPlaylist(playlistId) else { return }
        playlist.remove([sid])
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func bulkAddToPlaylist(_ playlistId: String, _ scoreIds: [String]) {
        guard var playlist = domainPlaylist(playlistId) else { return }
        let ids = scoreIds.compactMap(scoreItemID)
        guard !ids.isEmpty else { return }
        playlist.appendUnique(ids)
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func createPlaylistWithScores(_ name: String, _ scoreIds: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        playlist.appendUnique(scoreIds.compactMap(scoreItemID))
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func createPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        persist(Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date()))
        reloadPlaylists()
    }

    @WireletExpose
    public func renamePlaylist(_ id: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var playlist = domainPlaylist(id) else { return }
        playlist.name = trimmed
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func deletePlaylist(_ id: String) {
        store.deletePlaylist(id: id)
        if selectedPlaylistID == id { selectedPlaylistID = nil }
        reloadPlaylists()
    }

    @WireletExpose
    public func selectPlaylist(_ id: String) {
        selectedPlaylistID = id
        reloadPlaylists()
    }

    /// Reorder a playlist to the given live order. Members hidden from the UI
    /// (e.g. soft-deleted, not shown) are appended after, so they are not lost.
    @WireletExpose
    public func setPlaylistOrder(_ playlistId: String, _ orderedIds: [String]) {
        guard var playlist = domainPlaylist(playlistId) else { return }
        let members = Set(playlist.orderedScoreItemIDs)
        let requested = orderedIds.compactMap(scoreItemID).filter { members.contains($0) }
        let requestedSet = Set(requested)
        let hidden = playlist.orderedScoreItemIDs.filter { !requestedSet.contains($0) }
        playlist.orderedScoreItemIDs = requested + hidden
        persist(playlist)
        reloadPlaylists()
    }
}

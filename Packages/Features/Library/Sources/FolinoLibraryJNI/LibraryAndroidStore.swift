// The @WireletObservable bridge macro expands against members declared in this
// type's primary body, so every @WireletExpose method (scores, playlists, tags)
// must live here rather than in an extension — splitting them out would drop
// them from the generated Kotlin bridge. That keeps this file (and the type
// body) over the limit.
// swiftlint:disable file_length
// swiftlint:disable type_body_length
import Domain // ScoreFormat, ScorePresentation, ScoreShareFormat, ScoreExportNaming
import Foundation
import Observation

// SheetMusicMIDI (MidiRenderer/MidiWriter) is used directly rather than the umbrella `SheetMusic`, which
// `@_exported import`s SheetMusicCore and would make `ScoreItemID` ambiguous with Domain's.
import SheetMusicMIDI // MidiRenderer.render(score:), MidiWriter.write(_:)
import SheetMusicMSCX // MSCZReader.parse(contentsOf:), MSCZWriter, MSCXEncoderOptions
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
///
/// The @WireletExpose methods (scores, playlists, tags, export) are all forced into the primary body by the
/// bridge macro, so the class body exceeds the `type_body_length` limit by design (disabled below, re-enabled
/// at end of file).
@WireletObservable
@Observable
public final class LibraryAndroidStore {
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let pdfRenderer: ScorePdfRenderer
    @ObservationIgnored private let audioExporter: ScoreAudioFileExporter
    public var scores: [ScoreRowWire] = []
    public var deletedScores: [ScoreRowWire] = []
    public var favorites: [ScoreRowWire] = []

    public var recentToday: [ScoreRowWire] = []
    public var recentThisWeek: [ScoreRowWire] = []
    public var recentEarlier: [ScoreRowWire] = []

    public var playlists: [PlaylistRowWire] = []
    public var selectedPlaylistItems: [ScoreRowWire] = []
    public var addSheetPlaylists: [PlaylistPickWire] = []

    public var tags: [TagRowWire] = []
    public var selectedTagItems: [ScoreRowWire] = []
    public var editSheetTags: [TagPickWire] = []

    @ObservationIgnored private var selectedPlaylistID: String?
    @ObservationIgnored private var addSheetScoreID: String?

    // Set by selectTag (tag detail) and beginEditTags/beginBulkEditTags (edit sheet).
    @ObservationIgnored private var selectedTagID: String?
    @ObservationIgnored private var editSheetScoreID: String?

    // Search (iOS parity). `searchQuery` filters the three displayed score lists
    // via the shared Domain `ScoreSearch`. Unfiltered backings let setSearchQuery
    // recompute the observables without re-reading the backend.
    @ObservationIgnored private var searchQuery = ""
    @ObservationIgnored private var allScoreRows: [ScoreRowWire] = []
    @ObservationIgnored private var selectedPlaylistRows: [ScoreRowWire] = []
    @ObservationIgnored private var selectedTagRows: [ScoreRowWire] = []

    public init(store: LibraryStore, pdfRenderer: ScorePdfRenderer, audioExporter: ScoreAudioFileExporter) {
        self.store = store
        self.pdfRenderer = pdfRenderer
        self.audioExporter = audioExporter
        reload() // hydrate from persistence on launch
        reloadPlaylists()
        reloadTags()
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
            lastOpenedAt: 0,
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

    /// Stamp `lastOpenedAt = now` for `id` and rebuild the displayed lists. Called from the Android navigation
    /// layer the moment a score is opened (iOS parity: ReaderViewModel.updateLastOpenedAtOnce). Once per open by
    /// construction — the caller fires it once per navigation. Unknown id is a no-op.
    @WireletExpose
    public func markOpened(_ id: String) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].lastOpenedAt = Date().timeIntervalSince1970
        store.upsert(all[idx])
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }

    /// Mark a score as a favorite (iOS parity: flips `ScoreItem.isFavorite`).
    @WireletExpose
    public func favorite(_ id: String) {
        setFavorite(id, true)
    }

    /// Clear a score's favorite flag.
    @WireletExpose
    public func unfavorite(_ id: String) {
        setFavorite(id, false)
    }

    /// Bulk favorite (All Scores CAB). No-op for ids already favorited.
    @WireletExpose
    public func favoriteMany(_ ids: [String]) {
        setFavoriteMany(ids, true)
    }

    /// Bulk unfavorite (All Scores CAB). No-op for ids already not favorited.
    @WireletExpose
    public func unfavoriteMany(_ ids: [String]) {
        setFavoriteMany(ids, false)
    }

    private func setFavorite(_ id: String, _ value: Bool) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }), all[idx].isFavorite != value else { return }
        all[idx].isFavorite = value
        store.upsert(all[idx])
        reload(using: all)
    }

    private func setFavoriteMany(_ ids: [String], _ value: Bool) {
        let idSet = Set(ids)
        var all = store.loadAll()
        var changed = false
        for idx in all.indices where idSet.contains(all[idx].id) && all[idx].isFavorite != value {
            all[idx].isFavorite = value
            store.upsert(all[idx])
            changed = true
        }
        guard changed else { return }
        reload(using: all)
    }

    /// Set the search query and recompute the three displayed score lists from
    /// their unfiltered backings. iOS parity: empty query shows everything.
    @WireletExpose
    public func setSearchQuery(_ query: String) {
        searchQuery = query
        scores = searchFiltered(allScoreRows)
        favorites = searchFiltered(allScoreRows.filter(\.isFavorite))
        selectedPlaylistItems = searchFiltered(selectedPlaylistRows)
        selectedTagItems = searchFiltered(selectedTagRows)
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
        reloadTags()
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
        reloadTags()
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
        reloadTags()
    }

    private func setDeletedAt(_ id: String, _ stamp: Double) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].deletedAt = stamp
        store.upsert(all[idx])
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }

    /// Rebuild the displayed lists: live records (`deletedAt <= 0`) in `scores`, favorites in `favorites`,
    /// soft-deleted records (most-recently-trashed first) in `deletedScores`, and the recently-opened buckets
    /// (`recentToday`/`recentThisWeek`/`recentEarlier`, via `reloadRecents`), all projected to the display wire
    /// type. Pass `records` to reuse an already-loaded snapshot and avoid a second backend read.
    private func reload(using records: [ScoreRecordWire]? = nil) {
        let all = records ?? store.loadAll()
        allScoreRows = all
            .filter { $0.deletedAt <= 0 }
            .map(Self.row)
        scores = searchFiltered(allScoreRows)
        favorites = searchFiltered(allScoreRows.filter(\.isFavorite))
        // Recently Deleted: soft-deleted rows, most-recently-trashed first
        // (mirrors iOS RecentlyDeletedViewModel). Sorting happens here, before
        // projection, so ScoreRowWire need not carry deletedAt.
        deletedScores = all
            .filter { $0.deletedAt > 0 }
            .sorted { $0.deletedAt > $1.deletedAt }
            .map(Self.row)
        reloadRecents(from: all)
    }

    /// Live, opened records (deletedAt <= 0 && lastOpenedAt > 0), newest first, classified into the three
    /// recency buckets via the shared Domain classifier. Mirrors iOS recency grouping; uses the device's clock.
    private func reloadRecents(from records: [ScoreRecordWire]) {
        let calendar = Calendar.current
        let now = Date()
        let opened = records
            .filter { $0.deletedAt <= 0 && $0.lastOpenedAt > 0 }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        var today: [ScoreRowWire] = []
        var week: [ScoreRowWire] = []
        var earlier: [ScoreRowWire] = []
        for record in opened {
            let date = Date(timeIntervalSince1970: record.lastOpenedAt)
            switch RecencyBucket.classify(date, now: now, calendar: calendar) {
            case .today: today.append(Self.row(record))
            case .thisWeek: week.append(Self.row(record))
            case .earlier: earlier.append(Self.row(record))
            }
        }
        recentToday = today
        recentThisWeek = week
        recentEarlier = earlier
    }

    private static func row(_ record: ScoreRecordWire) -> ScoreRowWire {
        ScoreRowWire(
            id: record.id,
            title: record.title,
            subtitle: record.subtitle,
            composer: record.composer,
            isFavorite: record.isFavorite,
        )
    }

    /// Filter a row list by the current search query using the shared predicate.
    private func searchFiltered(_ rows: [ScoreRowWire]) -> [ScoreRowWire] {
        rows.filter { ScoreSearch.matches(title: $0.title, composer: $0.composer, query: searchQuery) }
    }

    // MARK: - Export

    /// Map a wire token to the shared Domain `ScoreShareFormat`. Unknown → nil.
    private func parseFormat(_ raw: String) -> ScoreShareFormat? {
        switch raw {
        case "museScoreV4": .museScoreV4
        case "museScoreV3": .museScoreV3
        case "pdf": .pdf
        case "midi": .midi
        case "audioM4A": .audioM4A
        default: nil
        }
    }

    /// Stable wire token for a `ScoreShareFormat` (paired with `parseFormat`).
    private func token(for format: ScoreShareFormat) -> String {
        switch format {
        case .museScoreV4: "museScoreV4"
        case .museScoreV3: "museScoreV3"
        case .pdf: "pdf"
        case .midi: "midi"
        case .audioM4A: "audioM4A"
        }
    }

    /// The export formats in display order plus which one re-emits the score's
    /// original bytes (the `isOriginal` row, per `ScoreShareFormat.matching`).
    /// Mirrors iOS `availableFormats(for:)`. Unknown id → empty list.
    @WireletExpose
    public func exportFormats(_ scoreId: String) -> [ScoreExportFormatWire] {
        guard let record = store.loadAll().first(where: { $0.id == scoreId }) else { return [] }
        let path = "\(store.scoresDirectoryPath())/\(record.localFileName)"
        let original: ScoreShareFormat? = {
            guard let score = try? MSCZReader.parse(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return ScoreShareFormat.matching(for: score.source)
        }()
        return ScoreShareFormat.allOrdered.map {
            ScoreExportFormatWire(format: token(for: $0), isOriginal: $0 == original)
        }
    }

    /// Materialize the chosen `format` for `scoreId` under `outDir` and return
    /// the produced file's absolute path (`""` on any failure). Mirrors iOS
    /// `prepareShare(item:format:)`: when the format matches the score's source
    /// the original bytes are copied verbatim; otherwise the file is re-encoded
    /// (MSCZ/MIDI in shared Swift) or rasterized via the injected Android-only
    /// PDF / M4A primitives.
    @WireletExpose
    public func exportScore(_ scoreId: String, _ format: String, _ outDir: String) -> String {
        guard let fmt = parseFormat(format),
              let record = store.loadAll().first(where: { $0.id == scoreId }) else { return "" }
        let sourcePath = "\(store.scoresDirectoryPath())/\(record.localFileName)"
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard let score = try? MSCZReader.parse(contentsOf: sourceURL) else { return "" }
        let title = ScoreExportNaming.sanitize(title: record.title)
        let outPath = "\(outDir)/\(title).\(fmt.canonicalExtension)"
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)

        if ScoreShareFormat.matching(for: score.source) == fmt {
            return (try? FileManager.default.copyItem(at: sourceURL, to: outURL)) != nil ? outPath : ""
        }
        switch fmt {
        case .museScoreV4: return writeMSCZ(score, to: outURL, target: .v4) ? outPath : ""
        case .museScoreV3: return writeMSCZ(score, to: outURL, target: .v3) ? outPath : ""
        case .midi: return writeMIDI(score, to: outURL) ? outPath : ""
        case .pdf: return pdfRenderer.renderPdf(sourcePath, outPath) ? outPath : ""
        case .audioM4A: return audioExporter.exportAudio(sourcePath, outPath) ? outPath : ""
        }
    }

    private func writeMIDI(_ score: Score, to url: URL) -> Bool {
        // Mirrors SheetMusic.exportMIDI(score:) — render to SMF, then write the bytes.
        guard let data = try? MidiWriter.write(MidiRenderer.render(score: score)) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private func writeMSCZ(_ score: Score, to url: URL, target: MSCXVersion) -> Bool {
        (try? MSCZWriter.write(score: score, options: MSCXEncoderOptions(targetVersion: target), to: url)) != nil
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
        reloadTags()
    }

    private func scoreItemID(_ raw: String) -> ScoreItemID? {
        UUID(uuidString: raw).map(ScoreItemID.init(rawValue:))
    }

    /// Project live records into the minimal `[ScoreOpenInfo]` the recently-used sort helpers consume.
    private func loadScoreOpenInfo(_ records: [ScoreRecordWire]) -> [ScoreOpenInfo] {
        var tagsByScore: [String: Set<TagID>] = [:]
        for item in store.loadTagItems() {
            guard let uuid = UUID(uuidString: item.tagId) else { continue }
            tagsByScore[item.scoreItemId, default: []].insert(TagID(rawValue: uuid))
        }
        return records.compactMap { record in
            guard let sid = scoreItemID(record.id) else { return nil }
            let opened = record.lastOpenedAt > 0 ? Date(timeIntervalSince1970: record.lastOpenedAt) : nil
            return ScoreOpenInfo(id: sid, lastOpenedAt: opened, tagIDs: tagsByScore[record.id] ?? [])
        }
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
        let openInfo = loadScoreOpenInfo(records)

        // Recently-used order (reorder, not top-N): limit == count keeps every playlist.
        playlists = playlistsByRecentlyUsed(domain, openInfo: openInfo, limit: domain.count)
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
            selectedPlaylistRows = []
            selectedPlaylistItems = []
            return
        }
        var rowByID: [ScoreItemID: ScoreRowWire] = [:]
        for record in records where record.deletedAt <= 0 {
            if let sid = scoreItemID(record.id) { rowByID[sid] = Self.row(record) }
        }
        selectedPlaylistRows = PlaylistPresentation
            .orderedLiveIDs(playlist, liveIDs: liveIDs)
            .compactMap { rowByID[$0] }
        selectedPlaylistItems = searchFiltered(selectedPlaylistRows)
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

    // MARK: - Tags

    /// tagId -> set of member scoreItemId strings, from the backend's join rows.
    private func tagMembership() -> [String: Set<String>] {
        var membership: [String: Set<String>] = [:]
        for item in store.loadTagItems() {
            membership[item.tagId, default: []].insert(item.scoreItemId)
        }
        return membership
    }

    /// Set of live (`deletedAt <= 0`) score id strings, for member-count math.
    /// String-keyed counterpart of `liveScoreIDs` — tag membership (`TagItemWire`)
    /// stores raw id strings, so the playlist code's `ScoreItemID` wrapper is skipped here.
    private func liveScoreIDStrings(_ records: [ScoreRecordWire]) -> Set<String> {
        Set(records.filter { $0.deletedAt <= 0 }.map(\.id))
    }

    /// Recompute every tag-derived observable from one backend snapshot.
    private func reloadTags() {
        let records = store.loadAll()
        let live = liveScoreIDStrings(records)
        let membership = tagMembership()
        let tagRecords = store.loadTags()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Recently-used order for the main tags list (reorder, not top-N): limit == count keeps every tag.
        // Domain tag identity is keyed by UUID, so we round-trip through `Tag` and map the result back to the
        // backend records via the id string. The edit sheet (`refreshEditSheet`) stays alphabetical.
        let openInfo = loadScoreOpenInfo(records)
        // Skip any non-UUID id rather than minting a fresh UUID (which would mismatch the membership key and emit a
        // phantom id to Kotlin) — mirrors `loadDomainPlaylists`. All ids written by this store are UUID strings.
        let domainTags = tagRecords.compactMap { rec -> Tag? in
            guard let uuid = UUID(uuidString: rec.id) else { return nil }
            return Tag(id: TagID(rawValue: uuid), name: rec.name, colorHex: rec.colorHex)
        }
        tags = tagsByRecentlyUsed(domainTags, openInfo: openInfo, limit: domainTags.count).map { tag in
            let id = tag.id.rawValue.uuidString
            let members = membership[id] ?? []
            return TagRowWire(
                id: id,
                name: tag.name,
                colorHex: tag.colorHex,
                memberCount: Int32(members.intersection(live).count),
            )
        }
        recomputeSelectedTagItems(records: records, membership: membership)
        refreshEditSheet(tagRecords: tagRecords, membership: membership)
    }

    /// Live scores carrying `selectedTagID`, sorted by title (tags are unordered).
    private func recomputeSelectedTagItems(records: [ScoreRecordWire], membership: [String: Set<String>]) {
        guard let sel = selectedTagID else {
            selectedTagRows = []
            selectedTagItems = []
            return
        }
        let members = membership[sel] ?? []
        selectedTagRows = records
            .filter { $0.deletedAt <= 0 && members.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map(Self.row)
        selectedTagItems = searchFiltered(selectedTagRows)
    }

    /// Edit-tags sheet rows: every tag, `contains` reflecting the focused score
    /// (nil focus = bulk sheet, all false).
    private func refreshEditSheet(tagRecords: [TagRecordWire], membership: [String: Set<String>]) {
        let focus = editSheetScoreID
        editSheetTags = tagRecords.map { rec in
            TagPickWire(
                id: rec.id,
                name: rec.name,
                contains: focus.map { (membership[rec.id] ?? []).contains($0) } ?? false,
            )
        }
    }

    @WireletExpose
    public func createTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // iOS parity: default color is purple; no picker.
        store.upsertTag(TagRecordWire(id: UUID().uuidString, name: trimmed, colorHex: "#5856D6"))
        reloadTags()
    }

    @WireletExpose
    public func renameTag(_ id: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let existing = store.loadTags().first(where: { $0.id == id }) else { return }
        store.upsertTag(TagRecordWire(id: id, name: trimmed, colorHex: existing.colorHex))
        reloadTags()
    }

    @WireletExpose
    public func deleteTag(_ id: String) {
        store.deleteTag(id: id)
        if selectedTagID == id { selectedTagID = nil }
        reloadTags()
    }

    /// Union-add a set of scores into one tag (bulk CAB). Never removes existing
    /// members; the per-tag slice of iOS `bulkAddTags`' union semantics.
    @WireletExpose
    public func bulkAddTag(_ tagId: String, _ scoreIds: [String]) {
        guard !scoreIds.isEmpty else { return }
        var members = tagMembership()[tagId] ?? []
        members.formUnion(scoreIds)
        store.replaceTagItems(tagId, members.map { TagItemWire(tagId: tagId, scoreItemId: $0) })
        reloadTags()
    }

    /// Toggle one score's membership in one tag (single-score edit sheet).
    @WireletExpose
    public func setTagAssigned(_ scoreId: String, _ tagId: String, _ assigned: Bool) {
        var members = tagMembership()[tagId] ?? []
        if assigned { members.insert(scoreId) } else { members.remove(scoreId) }
        store.replaceTagItems(tagId, members.map { TagItemWire(tagId: tagId, scoreItemId: $0) })
        reloadTags()
    }

    @WireletExpose
    public func selectTag(_ id: String) {
        selectedTagID = id
        reloadTags()
    }

    @WireletExpose
    public func beginEditTags(_ scoreId: String) {
        editSheetScoreID = scoreId
        reloadTags()
    }

    @WireletExpose
    public func beginBulkEditTags() {
        editSheetScoreID = nil
        reloadTags()
    }
}

// swiftlint:enable type_body_length

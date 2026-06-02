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

    public init(store: LibraryStore) {
        self.store = store
        reload() // hydrate from persistence on launch
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

    /// Permanent purge (iOS parity, `permanentlyDeleteScoreItem`): remove the
    /// managed file, then the record. Unknown id is a no-op.
    @WireletExpose
    public func permanentlyDelete(_ id: String) {
        let all = store.loadAll()
        guard let record = all.first(where: { $0.id == id }) else { return }
        store.removeFile(localFileName: record.localFileName)
        store.deleteRecord(id: id)
        reload()
    }

    /// Bulk restore (iOS `bulkRestore`): clear `deletedAt` for each id, then
    /// reload once. Unknown ids are skipped.
    @WireletExpose
    public func restoreMany(_ ids: [String]) {
        var all = store.loadAll()
        for id in ids {
            guard let idx = all.firstIndex(where: { $0.id == id }) else { continue }
            all[idx].deletedAt = 0
            store.upsert(all[idx])
        }
        reload(using: all)
    }

    /// Bulk permanent purge (iOS `bulkPermanentlyDelete`): remove file + record
    /// for each id, then reload once.
    @WireletExpose
    public func permanentlyDeleteMany(_ ids: [String]) {
        let idSet = Set(ids)
        for record in store.loadAll() where idSet.contains(record.id) {
            store.removeFile(localFileName: record.localFileName)
            store.deleteRecord(id: record.id)
        }
        reload()
    }

    private func setDeletedAt(_ id: String, _ stamp: Double) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].deletedAt = stamp
        store.upsert(all[idx])
        reload(using: all)
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
}

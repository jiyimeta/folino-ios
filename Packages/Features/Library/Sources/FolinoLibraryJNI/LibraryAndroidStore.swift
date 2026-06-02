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

    private func setDeletedAt(_ id: String, _ stamp: Double) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].deletedAt = stamp
        store.upsert(all[idx])
        reload(using: all)
    }

    /// Rebuild the displayed list: live records (`deletedAt <= 0`) projected to
    /// the display wire type. Pass `records` to reuse an already-loaded snapshot
    /// and avoid a second backend read.
    private func reload(using records: [ScoreRecordWire]? = nil) {
        scores = (records ?? store.loadAll())
            .filter { $0.deletedAt <= 0 }
            .map { ScoreRowWire(id: $0.id, title: $0.title, subtitle: $0.subtitle, composer: $0.composer) }
    }
}

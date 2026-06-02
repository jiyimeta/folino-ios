import Wirelet
import WireletProvided

/// Persistence backend for the Android Library, *implemented in Kotlin*
/// (`RoomLibraryStore`) and injected into `LibraryAndroidStore` over JNI.
///
/// This is a rule-free mechanism: it stores whatever `ScoreRecordWire` the
/// Swift store hands it (including the `deletedAt` the store computed) and
/// performs raw file copy/remove against the app's scores directory. All
/// decisions — when to soft-delete, how to name files, what to display — stay
/// in `LibraryAndroidStore`, in lockstep with the iOS implementation.
@WireletProvided
public protocol LibraryStore {
    /// Every persisted row, including soft-deleted ones (`deletedAt > 0`).
    func loadAll() -> [ScoreRecordWire]

    /// Insert or replace by `record.id`.
    func upsert(_ record: ScoreRecordWire)

    /// Copy the imported file at `sourcePath` into the managed scores directory
    /// under `localFileName` (`"<id>.mscz"`). Overwrites if present.
    func copyImportedFile(fromPath sourcePath: String, localFileName: String)

    /// Remove a managed score file. Used by permanent purge (a future Trash
    /// screen); soft-delete does **not** call this.
    func removeFile(localFileName: String)

    /// Permanently remove a persisted row by id. Pairs with `removeFile` for a
    /// full purge (the Swift store calls both). Soft-delete does **not** call this.
    func deleteRecord(id: String)
}

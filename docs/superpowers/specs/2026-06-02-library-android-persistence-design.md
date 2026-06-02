# Library Android persistence — design

**Status**: Spec (brainstorming complete, awaiting plan)
**Date**: 2026-06-02
**Author**: Kiichi Ito (with Claude)
**Branch**: `android-library-pilot`
**Builds on**: [Library Android pilot](./2026-06-01-library-android-pilot-design.md)

## Purpose

Give the Android Library its first **persistence**: imported scores (the row metadata **and** the `.mscz` file itself) survive an app restart, and deletion becomes a **soft delete** that can be undone. This is the first Folino feature to drive the **`@WireletProvided`** capability (swift-wirelet v0.3.0) — a Kotlin-implemented service injected into a Swift `@WireletObservable` view-model over JNI.

The pilot (commit `732a83c`) shipped a one-screen in-memory slice: import `.mscz` → row appears → tap → stub Reader → swipe-delete + Snackbar undo, with nothing surviving a restart and the `.mscz` bytes discarded. This work makes that slice durable.

## Guiding principle (from CLAUDE.md "iOS / Android parity")

- **Logic / behavior → match iOS exactly, and share the code.** The persistence *rules* — soft-delete representation, file-naming convention, the import sequence, the display projection — live in **shared Swift** (Domain, or the Android-gated Swift store) and mirror the iOS implementation. We do **not** reimplement those rules a second time in Kotlin.
- **Android-only code is the minimum that can only be done on Android**: the Room/SQLite backend, Android file I/O (`filesDir`), the Compose UI, and the JNI/wire types.
- **UI/UX placement** follows Android idioms (FAB import, swipe-to-dismiss + Snackbar undo); only the *content* keeps iOS parity.

## How this maps to the iOS implementation (parity reference)

| iOS concern | iOS implementation | Android equivalent in this design |
|---|---|---|
| Soft-delete representation | `ScoreItem.deletedAt: Date?`; `UPDATE … SET deleted_at = now / NULL` | `ScoreRecordWire.deletedAt: Double` (`0` = not deleted); set/cleared **in Swift** |
| File-naming | `"\(id.rawValue.uuidString).\(format.canonicalExtension)"` (`LiveScoreFileImporter`) | same convention, built **in Swift** via `ScoreFormat.mscz.canonicalExtension` |
| Display projection | `ScorePresentation.displayFields(sourceFilename:score:)` (Domain, already shared) | **same call** — already reused by the pilot store |
| Score directory | `AppPaths.scoresDirectory` (`Documents/Scores`, Apple `FileManager`) | Kotlin `context.filesDir/Scores` — Android-only path resolution |
| File retained until permanent purge | soft-delete keeps the file; `permanentlyDelete` / 30-day `prune` removes it | soft-delete keeps the file; permanent purge is **future** (no Trash screen yet) |
| Persistence backend | GRDB SQLite (`LiveScoreLibraryRepository`, Infrastructure) | Room SQLite (Kotlin) — Android-only backend |

The iOS `ScoreLibraryRepository` protocol is `async` and traffics in the rich Domain `ScoreItem`; neither crosses the JNI bridge (sync-only, `@WireFormat`-only). So Android cannot literally call iOS's repository. Instead we keep the **decision logic in Swift** and expose Kotlin only as a dumb persistence primitive — see Architecture.

## Architecture

```
 Compose LibraryScreen
   │  vm.importScore(path) / vm.delete(id) / vm.restore(id)
   ▼
 LibraryAndroidStore  (Swift, @WireletObservable @Observable)   ← ALL business logic
   │   • import sequencing, file-name building (ScoreFormat), display projection (ScorePresentation)
   │   • soft-delete = set deletedAt; restore = clear deletedAt; filter for display
   │   var scores: [ScoreRowWire]                                → StateFlow<List<ScoreRowWire>>
   │   store.loadAll() / upsert(_) / copyImportedFile(…) / removeFile(…)
   ▼
 LibraryStore  (@WireletProvided protocol, implemented in Kotlin)   ← Android-only, NO rules
   │   • Room CRUD of ScoreRecordWire rows (stores verbatim, incl. deletedAt)
   │   • filesDir/Scores file copy + remove
   ▼
 Room (SQLite)  +  context.filesDir/Scores/<id>.mscz
```

**Division of responsibility**

- **Swift `LibraryAndroidStore`** owns every rule that iOS owns: the import sequence, `<id>.<canonicalExtension>` naming, the `deletedAt`-timestamp soft-delete model, restore, and the display filter/projection. This is the parity-faithful, lift-ready layer.
- **Kotlin `LibraryStore`** is a *mechanism only*: it persists whatever `ScoreRecordWire` it is handed (including the `deletedAt` value Swift computed) and performs raw file copy/remove against `filesDir`. It makes **no** decisions about when to delete, how to name files, or what to show.

### Swift side (`Packages/Features/Library/Sources/FolinoLibraryJNI/`)

Two wire types — a **display** projection (unchanged from the pilot) and a **persistence** projection:

```swift
import Wirelet

// Display projection — crosses to Compose. Unchanged from the pilot.
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
}

// Persistence projection — crosses to the Kotlin/Room backend.
@WireFormat
public struct ScoreRecordWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var localFileName: String   // "<id>.mscz" — built in Swift, iOS convention
    public var deletedAt: Double        // 0 == not deleted (mirrors iOS deletedAt: Date?)
}
```

The injected Kotlin backend protocol (Swift-declared, Kotlin-implemented):

```swift
import Wirelet
import WireletProvided

@WireletProvided
public protocol LibraryStore {
    func loadAll() -> [ScoreRecordWire]                                  // ALL rows, incl. soft-deleted
    func upsert(_ record: ScoreRecordWire)                              // insert or replace by id
    func copyImportedFile(fromPath sourcePath: String, localFileName: String)  // temp → filesDir/Scores/<name>
    func removeFile(localFileName: String)                             // permanent-purge use (future)
}
```

The store — logic identical in spirit to iOS:

```swift
import Domain                 // ScoreFormat, ScorePresentation
import Foundation
import Observation
import SheetMusicMSCX         // MSCZReader.parse(contentsOf:)
import Wirelet
import WireletObservable
import WireletProvided

@WireletObservable
@Observable
public final class LibraryAndroidStore {
    @ObservationIgnored private let store: LibraryStore
    public var scores: [ScoreRowWire] = []      // → StateFlow; only non-deleted rows

    public init(store: LibraryStore) {
        self.store = store
        reload()                                // hydrate from persistence on launch
    }

    @WireletExpose
    public func importScore(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let score = try? MSCZReader.parse(contentsOf: url) else { return }
        let fields = ScorePresentation.displayFields(sourceFilename: url.lastPathComponent, score: score)
        let id = UUID().uuidString
        let localFileName = "\(id).\(ScoreFormat.mscz.canonicalExtension)"   // shared iOS convention
        store.copyImportedFile(fromPath: path, localFileName: localFileName)
        store.upsert(ScoreRecordWire(
            id: id, title: fields.title, subtitle: fields.subtitle ?? "",
            composer: fields.composer ?? "", localFileName: localFileName, deletedAt: 0,
        ))
        reload()
    }

    @WireletExpose public func delete(_ id: String)  { setDeletedAt(id, Date().timeIntervalSince1970) }  // soft
    @WireletExpose public func restore(_ id: String) { setDeletedAt(id, 0) }                              // undo

    private func setDeletedAt(_ id: String, _ stamp: Double) {
        guard var record = store.loadAll().first(where: { $0.id == id }) else { return }
        record.deletedAt = stamp
        store.upsert(record)
        reload()
    }

    private func reload() {
        scores = store.loadAll()
            .filter { $0.deletedAt == 0 }
            .map { ScoreRowWire(id: $0.id, title: $0.title, subtitle: $0.subtitle, composer: $0.composer) }
    }
}
```

Notes:
- The pilot's `insert(_ row:)` is **removed**; undo is now `restore(_ id:)` (sets `deletedAt = 0`), so the soft-deleted file is reused rather than re-imported.
- `ScoreRowWire` is unchanged — Compose and the bridge contract for display do not change.
- `ScoreFormat` and `ScorePresentation` come from **Domain** (already a dependency of `FolinoLibraryJNI`); no logic is re-derived on the Kotlin side.

### Kotlin side (`Android/FolinoLibraryAndroid` + `app`)

- Generated `@WireletProvided` interface `LibraryStore` (friendly Kotlin signatures) + its native adapter, via the Gradle `provided { register("main") { … } }` block (mirrors the v0.3.0 `observable-counter` example). The `observable { … }` block gains `providedAdapterPackage`.
- `RoomLibraryStore(context) : LibraryStore` — the only Android-specific persistence code:
  - **Room**: `@Entity ScoreRecordEntity(id PK, title, subtitle, composer, localFileName, deletedAt: Double)` ↔ 1:1 with `ScoreRecordWire`; `@Dao LibraryDao` (`upsert`, `loadAll`); `@Database AppDatabase`.
  - `loadAll()` → all rows as `ScoreRowWire`/`ScoreRecordWire`. `upsert(record)` → `INSERT OR REPLACE`.
  - `copyImportedFile(fromPath, localFileName)` → copy/move the Kotlin-staged temp file into `filesDir/Scores/<localFileName>`.
  - `removeFile(localFileName)` → delete from `filesDir/Scores` (used by future permanent purge).
- `ViewModelFactory`: builds `RoomLibraryStore(applicationContext)` and injects it — `LibraryAndroidStoreViewModel.create(store = RoomLibraryStore(applicationContext))` (mirrors the example's `create(store = InMemoryTodoStore())`).
- Gradle deps: add `androidx.room:room-runtime` + KSP `room-compiler`. (No `kotlinx.serialization`.)

### Compose side

- Unchanged structure. Swipe-to-dismiss → `vm.delete(id)`; Snackbar "Score deleted · UNDO" → `vm.restore(id)` (the row id is held in Compose state for the Snackbar's lifetime).
- Import (FAB → document picker) and tap → stub Reader are unchanged.

## Data contract

| Swift | Kotlin (generated / written) |
|---|---|
| `var scores: [ScoreRowWire]` | `val scores: StateFlow<List<ScoreRowWire>>` |
| `func importScore(_ path: String)` | `fun importScore(path: String)` |
| `func delete(_ id: String)` | `fun delete(id: String)` |
| `func restore(_ id: String)` | `fun restore(id: String)` |
| `@WireletProvided protocol LibraryStore` | `interface LibraryStore` + `LibraryStoreNativeAdapter`, implemented by `RoomLibraryStore` |
| `struct ScoreRecordWire` | `data class ScoreRecordWire(id, title, subtitle, composer, localFileName, deletedAt)` + Room entity |

## Build / codegen wiring

- **Swift** (`Packages/Features/Library/Package.swift`, `isAndroid` branch): add `WireletProvided` to `FolinoLibraryJNI`'s deps and the `WireletProvidedBridges` build-tool plugin alongside the existing `WireletObservableBridges`.
- **Cross-compile**: the existing `libFolinoLibraryJNI.so` build picks up the new types/protocol; no new `.so`.
- **Gradle** (`Android/FolinoLibraryAndroid`): add `provided { register("main") { … } }`, `providedAdapterPackage` on the `observable` block, and the Room dependencies + KSP plugin.

## Dependency notes

- **swift-wirelet** must be at **v0.3.0** (`@WireletProvided` shipped there; tag `ed13304`). Bump the pin in every Folino `Package.swift` that references it **and** `project.yml`'s `packages:` entry (repo dual-update rule). The pilot pinned v0.2.2; this is a version bump (auto-approved).
- **Room** (`androidx.room`) is a new Gradle (Android-only) dependency, not a SwiftPM one — outside the SwiftPM "stop and confirm" rule, but called out here for visibility.

## Out of scope (future phases)

- **Recently Deleted (Trash) screen + permanent delete + 30-day prune.** The `deletedAt` model and `removeFile` are in place so these are additive; the iOS `pruneScoreItemsDeleted(before:)` / `permanentlyDeleteScoreItem` behavior is the parity target when that screen lands.
- **Fuller `ScoreItem`-field parity** (contentHash for duplicate detection, addedAt/lastOpenedAt for sort, isFavorite, tags). The pilot record stays the lean 6-field projection; fields arrive with the features that need them.
- **Real Reader** (rendering/audio). The retained `.mscz` at `filesDir/Scores/<id>.mscz` is the groundwork; resolving and parsing it for a real Reader is a separate spec.
- **A fully shared `LibraryStoreCore<Backend>`** consumed by *both* iOS and Android (refactoring the iOS `ScoreLibraryRepository`/`LiveScoreLibraryRepository`). That touches a Domain protocol across multiple Features and is a **stop-and-confirm architectural change** — explicitly not attempted here. This design keeps the Android logic in Swift and parity-faithful so the future extraction is mechanical.

## Risks & validation order

1. **`@WireletProvided` injection on device (highest value).** First Folino use of the v0.3.0 provided bridge. The capability is device-verified in swift-wirelet's `observable-counter` example (`create(store = …)` + `nativeNew(service:)`), but Folino's two-`.so` app and Room backend are new. Smoke the injected round-trip first (a trivial `LibraryStore` returning a fixed row) before wiring Room.
2. **Room on the JNI sync path.** `loadAll()` runs on whatever thread calls the bridged method — at init (main) and after each mutation. For the pilot's tiny list, use `allowMainThreadQueries()`, with a documented follow-up to a Kotlin in-memory cache + background Room write-through. Re-evaluate if jank appears.
3. **File copy/retention.** Confirm the imported `.mscz` lands at `filesDir/Scores/<id>.mscz` and survives restart; confirm soft-delete keeps the file and restore re-shows the row.
4. **`Double` over the wire.** `ScoreRecordWire.deletedAt: Double` marshals as `fixed64` (wire-format spec). Verified supported; smoke once in the Phase 0 round-trip.

## Testing strategy

| Layer | Location | Coverage |
|---|---|---|
| Swift store logic | `Packages/Features/Library/Tests/FolinoLibraryJNITests/` (Swift Testing, host/macOS) | Against a fake in-memory `LibraryStore`: import parses a fixture `.mscz` → correct `ScoreRowWire` + a persisted `ScoreRecordWire` with `deletedAt == 0` and `<id>.mscz` name; `delete` sets `deletedAt` and hides the row; `restore` clears it and re-shows; `reload` filters soft-deleted. |
| Wire types | same | `ScoreRecordWire` encode/decode round-trip (incl. `Double` field) — parity with the Kotlin codec. |
| Kotlin backend | `RoomLibraryStore` (instrumented or Robolectric) | `upsert`/`loadAll` round-trip incl. `deletedAt`; `copyImportedFile` writes into `filesDir/Scores`; soft-delete keeps the file; `removeFile` deletes it. |
| Kotlin VM generation | Gradle build | `LibraryStore` interface + adapter + `LibraryAndroidStoreViewModel.create(store=)` generated with the expected surface. |
| Android smoke | manual (user, clean build) | Import a real `.mscz` → **restart app → row still present**; swipe-delete → row gone + Undo restores; the `.mscz` file is present under `filesDir/Scores`. Claude builds; the user performs device gestures. |

## Phasing (for the implementation plan)

0. **De-risk** — bump swift-wirelet to v0.3.0; smoke a trivial injected `@WireletProvided LibraryStore` (fixed row, no Room) end-to-end on device to validate the provided bridge in Folino's two-`.so` app + the `Double` wire field.
1. **Swift store + wire types** — `ScoreRecordWire`, `LibraryStore` protocol, the rewritten `LibraryAndroidStore` (import/delete/restore/reload), host-side tests against a fake `LibraryStore`.
2. **Kotlin Room backend** — `ScoreRecordEntity`/`LibraryDao`/`AppDatabase`, `RoomLibraryStore`, file copy into `filesDir/Scores`, Gradle `provided{}` + Room deps, `ViewModelFactory` injection.
3. **Compose wiring** — repoint undo to `restore(id)`; verify import/list/swipe-delete unchanged.
4. **End-to-end smoke** — build the APK; hand to the user for device verification (restart-persistence + undo + file retention).

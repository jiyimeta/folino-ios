# Library Android persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Android Library imports durable — the row metadata and the `.mscz` file survive an app restart, and deletion is a soft-delete that Undo restores — by injecting a Kotlin/Room persistence backend into the Swift store via swift-wirelet's `@WireletProvided` capability.

**Architecture:** All persistence *logic* (import sequencing, `<id>.mscz` naming, `deletedAt`-timestamp soft-delete, display projection) lives in the Swift `@WireletObservable` `LibraryAndroidStore`, mirroring the iOS implementation and reusing Domain (`ScoreFormat`, `ScorePresentation`). The injected `@WireletProvided` Kotlin `LibraryStore` is a thin, rule-free backend: Room CRUD of a record row + raw `filesDir/Scores` file copy/remove.

**Tech Stack:** Swift 6.3 (FolinoLibraryJNI, Foundation-only), swift-wirelet v0.3.0 (`@WireletObservable` + `@WireletProvided` JNI bridges), Kotlin + androidx.room (SQLite) + Jetpack Compose, swift-sheet-music (`MSCZReader`).

**Reference spec:** `docs/superpowers/specs/2026-06-02-library-android-persistence-design.md`

**Parity rule (CLAUDE.md "iOS / Android parity"):** logic mirrors iOS and is shared; Android-only code is the minimum that can only be done on Android; UI placement follows Android idioms.

---

## File map

**Swift (`Packages/Features/Library/`)**
- Modify: `Package.swift` — add `WireletProvided` product dep + `WireletProvidedBridges` plugin to `FolinoLibraryJNI`; bump wirelet revision.
- Create: `Sources/FolinoLibraryJNI/ScoreRecordWire.swift` — persistence wire projection.
- Create: `Sources/FolinoLibraryJNI/LibraryStore.swift` — `@WireletProvided` backend protocol.
- Modify: `Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — inject `LibraryStore`; import/delete/restore/reload logic.
- Modify: `Sources/FolinoLibraryJNI/ScoreRowWire.swift` — unchanged (display projection); listed for orientation only.
- Modify: `Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` — drive against an in-memory fake `LibraryStore`.

**Kotlin (`Android/`)**
- Modify: `FolinoLibraryAndroid/build.gradle.kts` — bump wirelet to 0.3.0; add `provided { }` + `providedAdapterPackage`; add Room + KSP; wire provided codegen srcDir.
- Create: `FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — Room entity/DAO/DB + `LibraryStore` impl.
- Modify: `app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — inject `RoomLibraryStore` via `create(store = …)`.
- Modify: `app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` — Undo calls `viewModel.restore(row.id)` instead of `insert(row)`.

**Build**
- `Scripts/android-build-library-libs.sh` — unchanged (rebuilds `libFolinoLibraryJNI.so` with the new types automatically).

---

## Task 0: Bump swift-wirelet to v0.3.0

`@WireletProvided` shipped in v0.3.0. The bump is source-compatible (additive). Folino pins wirelet by revision only in the Android-gated `Package.swift`; `project.yml` does **not** reference wirelet, so no dual-update is needed here.

**Files:**
- Modify: `Packages/Features/Library/Package.swift:25`
- Modify: `Android/FolinoLibraryAndroid/build.gradle.kts:4,26-27`

- [ ] **Step 1: Bump the Swift package revision**

In `Packages/Features/Library/Package.swift`, replace the wirelet revision (line ~25):

```swift
// swiftlint:disable:next line_length
.package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "ed133041964cea5c8b32d03a575334dda8861fa0"),
```

- [ ] **Step 2: Bump the Gradle plugin + runtime versions**

In `Android/FolinoLibraryAndroid/build.gradle.kts`, change the three `0.2.2` occurrences to `0.3.0`:

```kotlin
id("io.github.jiyimeta.wirelet") version "0.3.0"
// …
api("io.github.jiyimeta:wirelet-runtime:0.3.0")
api("io.github.jiyimeta:wirelet-observable-runtime:0.3.0")
```

- [ ] **Step 3: Resolve + verify the Swift package still builds on host**

Run: `FOLINO_ANDROID=1 swift build --package-path Packages/Features/Library`
Expected: `Build complete!` (wirelet v0.3.0 resolves; existing pilot code compiles unchanged).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Package.swift Android/FolinoLibraryAndroid/build.gradle.kts
git commit -m "build(android): bump swift-wirelet to v0.3.0 for @WireletProvided"
```

---

## Task 1: Swift persistence wire type + `@WireletProvided` backend protocol

Introduce the persistence projection and the backend protocol, and wire the `WireletProvided` product + build-tool plugin into the JNI target. The store is not changed yet, so the build stays green.

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`
- Modify: `Packages/Features/Library/Package.swift:40-46`

- [ ] **Step 1: Add the `WireletProvided` product + plugin to the JNI target**

In `Packages/Features/Library/Package.swift`, in the `FolinoLibraryJNI` target's `dependencies` add the product, and in `plugins` add the bridges plugin:

```swift
.target(
    name: "FolinoLibraryJNI",
    dependencies: [
        "Domain",
        .product(name: "Wirelet", package: "swift-wirelet"),
        .product(name: "WireletObservable", package: "swift-wirelet"),
        .product(name: "WireletProvided", package: "swift-wirelet"),
        .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
    ],
    plugins: [
        .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
        .plugin(name: "WireletProvidedBridges", package: "swift-wirelet"),
    ],
),
```

- [ ] **Step 2: Create the persistence wire type**

Create `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift`:

```swift
import Wirelet

/// Persistence projection of a score, marshaled across the JNI boundary to the
/// Kotlin/Room backend as `data class ScoreRecordWire(...)`. Distinct from
/// `ScoreRowWire` (the display projection) because it carries the persisted
/// fields the backend stores verbatim: the on-disk file name and the
/// soft-delete timestamp.
///
/// `deletedAt` mirrors the iOS `ScoreItem.deletedAt: Date?`: it is the Unix
/// time (`Date.timeIntervalSince1970`) at which the row was soft-deleted, or
/// `0` when the row is live. (`0` — 1970 — is never a real deletion instant,
/// so it is a safe "not deleted" sentinel and avoids marshaling an Optional.)
@WireFormat
public struct ScoreRecordWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var localFileName: String   // "<id>.mscz" — built in Swift, iOS naming convention
    public var deletedAt: Double        // 0 == live; >0 == soft-deleted at that Unix time

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        localFileName: String,
        deletedAt: Double,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.localFileName = localFileName
        self.deletedAt = deletedAt
    }
}
```

- [ ] **Step 3: Create the `@WireletProvided` backend protocol**

Create `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`:

```swift
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
}
```

- [ ] **Step 4: Verify host build compiles**

Run: `FOLINO_ANDROID=1 swift build --package-path Packages/Features/Library`
Expected: `Build complete!` (on Apple host the `@WireFormat`/`@WireletProvided` macros are inert; the protocol and struct compile as ordinary Swift).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Package.swift \
  Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift \
  Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift
git commit -m "feat(android): add ScoreRecordWire + @WireletProvided LibraryStore protocol"
```

---

## Task 2: Rewrite `LibraryAndroidStore` to own the persistence logic (host TDD)

The store moves from in-memory to injected-backend. Logic mirrors iOS: import builds `<id>.mscz` via `ScoreFormat.canonicalExtension`, persists a live record, and reloads; delete sets `deletedAt`; restore clears it; display filters live rows. Test on the macOS host against an in-memory fake `LibraryStore`.

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests against a fake backend**

Replace the entire contents of `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`:

```swift
@testable import FolinoLibraryJNI
import Foundation
import Testing

/// In-memory fake of the Kotlin/Room backend. Records the copied files so the
/// store's file-naming + copy orchestration can be asserted on the host.
private final class FakeLibraryStore: LibraryStore {
    var records: [ScoreRecordWire] = []
    var copiedFiles: [(sourcePath: String, localFileName: String)] = []
    var removedFiles: [String] = []

    func loadAll() -> [ScoreRecordWire] { records }

    func upsert(_ record: ScoreRecordWire) {
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
    }

    func copyImportedFile(fromPath sourcePath: String, localFileName: String) {
        copiedFiles.append((sourcePath, localFileName))
    }

    func removeFile(localFileName: String) { removedFiles.append(localFileName) }
}

struct LibraryAndroidStoreTests {
    /// The fixture's on-disk path (importScore takes a filesystem path).
    private func samplePath() throws -> String {
        try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz")).path
    }

    @Test func `init hydrates live rows from the backend`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 0),
            ScoreRecordWire(id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz", deletedAt: 123),
        ]
        let store = LibraryAndroidStore(store: backend)
        // Only the live row (deletedAt == 0) is displayed.
        #expect(store.scores.map(\.id) == ["a"])
    }

    @Test func `import derives fields, names the file <id>.mscz, persists a live record`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.importScore(try samplePath())

        #expect(store.scores.count == 1)
        let row = try #require(store.scores.first)
        // Title is the file name (sans extension) — matches the iOS importer,
        // NOT the score's workTitle metaTag ("アイデア#0131").
        #expect(row.title == "sample")
        #expect(row.composer == "Kiichi")

        let record = try #require(backend.records.first)
        #expect(record.deletedAt == 0)
        #expect(record.localFileName == "\(record.id).mscz")
        #expect(record.id == row.id)
        // The imported file was copied under the same name.
        #expect(backend.copiedFiles.count == 1)
        #expect(backend.copiedFiles.first?.localFileName == record.localFileName)
    }

    @Test func `delete soft-deletes: row hidden, record kept with deletedAt set, file NOT removed`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.importScore(try samplePath())
        let id = try #require(store.scores.first?.id)

        store.delete(id)

        #expect(store.scores.isEmpty)                       // hidden from display
        let record = try #require(backend.records.first { $0.id == id })
        #expect(record.deletedAt > 0)                       // soft-deleted
        #expect(backend.removedFiles.isEmpty)               // file retained
    }

    @Test func `restore clears deletedAt and re-shows the row`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.importScore(try samplePath())
        let id = try #require(store.scores.first?.id)
        store.delete(id)
        #expect(store.scores.isEmpty)

        store.restore(id)

        #expect(store.scores.map(\.id) == [id])
        let record = try #require(backend.records.first { $0.id == id })
        #expect(record.deletedAt == 0)
    }

    @Test func `import of nonexistent path is ignored`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.importScore("/no/such/file.mscz")
        #expect(store.scores.isEmpty)
        #expect(backend.records.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `FOLINO_ANDROID=1 swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: FAIL — `LibraryAndroidStore` has no `init(store:)` / `restore(_:)` yet (compile error).

- [ ] **Step 3: Rewrite the store**

Replace the entire contents of `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`:

```swift
import Domain                 // ScoreFormat, ScorePresentation
import Foundation
import Observation
import SheetMusicMSCX         // MSCZReader.parse(contentsOf:)
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
        reload()   // hydrate from persistence on launch
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
        guard var record = store.loadAll().first(where: { $0.id == id }) else { return }
        record.deletedAt = stamp
        store.upsert(record)
        reload()
    }

    /// Rebuild the displayed list: live records (`deletedAt == 0`) projected to
    /// the display wire type.
    private func reload() {
        scores = store.loadAll()
            .filter { $0.deletedAt == 0 }
            .map { ScoreRowWire(id: $0.id, title: $0.title, subtitle: $0.subtitle, composer: $0.composer) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `FOLINO_ANDROID=1 swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift \
  Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android): LibraryAndroidStore persists via injected backend with soft-delete"
```

---

## Task 3: Kotlin Room backend (`RoomLibraryStore`) + Gradle wiring

Implement the `@WireletProvided`-generated `LibraryStore` interface with Room + `filesDir/Scores`. This is the only new Android-specific code. The generated interface/adapter come from the new `provided { }` block; the observable VM's injected `create(store = …)` factory comes from `providedAdapterPackage` on the `observable` block.

**Files:**
- Modify: `Android/FolinoLibraryAndroid/build.gradle.kts`
- Create: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

- [ ] **Step 1: Add Room + KSP, the `provided { }` block, and `providedAdapterPackage`**

In `Android/FolinoLibraryAndroid/build.gradle.kts`:

(a) Add KSP to the `plugins { }` block:

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp") version "2.0.21-1.0.27"
    id("io.github.jiyimeta.wirelet") version "0.3.0"
}
```

(b) Add Room deps to `dependencies { }`:

```kotlin
dependencies {
    api("io.github.jiyimeta:wirelet-runtime:0.3.0")
    api("io.github.jiyimeta:wirelet-observable-runtime:0.3.0")
    api("androidx.lifecycle:lifecycle-viewmodel:2.8.7")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.room:room-runtime:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
}
```

(c) Add `providedAdapterPackage` to the existing `observable { register("main") { … } }` block (after `libraryName`):

```kotlin
    observable {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Library/Sources/FolinoLibraryJNI"))
            viewModelPackage.set("com.keynumber.folino.library.generated")
            modelPackage.set("com.keynumber.folino.library")
            codecPackage.set("com.keynumber.folino.library")
            libraryName.set("FolinoLibraryJNI")
            providedAdapterPackage.set("com.keynumber.folino.library")
        }
    }
```

(d) Add a `provided { }` block inside `wirelet { }` (after `observable { }`):

```kotlin
    provided {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Library/Sources/FolinoLibraryJNI"))
            interfacePackage.set("com.keynumber.folino.library")
            adapterPackage.set("com.keynumber.folino.library")
            modelPackage.set("com.keynumber.folino.library")
            codecPackage.set("com.keynumber.folino.library")
        }
    }
```

- [ ] **Step 2: Wire the generated provided-interfaces srcDir (kotlin.android needs it manually)**

In the same file, extend the manual codegen wiring block (mirroring the existing codec/viewmodel wiring) to include the provided task:

```kotlin
// kotlin.android needs the generated dirs wired manually (the plugin hooks
// kotlin.jvm only). Mirror the Settings module's pattern for the codec,
// observable viewmodel, AND provided-interfaces tasks.
val generateCodecs = tasks.named("generateWireletCodecsMain")
val generateViewModels = tasks.named("generateWireletObservableViewModelsMain")
val generateProvided = tasks.named("generateWireletProvidedInterfacesMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateCodecs.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateViewModels.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletObservableViewModels).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateProvided.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletProvidedInterfaces).outputDir }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateCodecs, generateViewModels, generateProvided) }
```

- [ ] **Step 3: Implement `RoomLibraryStore`**

Create `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`:

```kotlin
package com.keynumber.folino.library

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import java.io.File

/** Room row — 1:1 with the Swift `ScoreRecordWire`. */
@Entity(tableName = "score_records")
data class ScoreRecordEntity(
    @PrimaryKey val id: String,
    val title: String,
    val subtitle: String,
    val composer: String,
    @ColumnInfo(name = "local_file_name") val localFileName: String,
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
)

@Dao
interface ScoreRecordDao {
    @Query("SELECT * FROM score_records")
    fun loadAll(): List<ScoreRecordEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(record: ScoreRecordEntity)
}

@Database(entities = [ScoreRecordEntity::class], version = 1)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
}

/**
 * Kotlin implementation of the generated `@WireletProvided` `LibraryStore`
 * interface, injected into the Swift `LibraryAndroidStore` over JNI.
 *
 * Rule-free backend: it persists whatever record the Swift store hands it
 * (including the `deletedAt` the store computed) and copies/removes files under
 * `filesDir/Scores`. All policy lives in Swift.
 *
 * Room queries run synchronously on the calling (JNI) thread. The pilot's list
 * is tiny, so `allowMainThreadQueries()` is acceptable here; the follow-up is a
 * Kotlin in-memory cache with background write-through (see spec §Risks).
 */
class RoomLibraryStore(context: Context) : LibraryStore {
    private val db = Room.databaseBuilder(
        context.applicationContext,
        LibraryDatabase::class.java,
        "folino-library.db",
    ).allowMainThreadQueries().build()

    private val dao = db.dao()

    private val scoresDir: File =
        File(context.applicationContext.filesDir, "Scores").apply { mkdirs() }

    override fun loadAll(): List<ScoreRecordWire> =
        dao.loadAll().map {
            ScoreRecordWire(it.id, it.title, it.subtitle, it.composer, it.localFileName, it.deletedAt)
        }

    override fun upsert(record: ScoreRecordWire) {
        dao.upsert(
            ScoreRecordEntity(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                composer = record.composer,
                localFileName = record.localFileName,
                deletedAt = record.deletedAt,
            ),
        )
    }

    override fun copyImportedFile(fromPath: String, localFileName: String) {
        File(fromPath).copyTo(File(scoresDir, localFileName), overwrite = true)
    }

    override fun removeFile(localFileName: String) {
        File(scoresDir, localFileName).delete()
    }
}
```

Note: the generated `LibraryStore` interface uses the Swift parameter *labels*; confirm the generated signature is `fun copyImportedFile(fromPath: String, localFileName: String)`. If the emitter drops the `fromPath` label (uses the internal name `sourcePath`), match the generated name. Read `FolinoLibraryAndroid/build/generated/.../LibraryStore.kt` after the first Gradle codegen run to confirm, and adjust the `override` signature accordingly.

- [ ] **Step 4: Run Gradle codegen + compile the module**

Run: `./Android/gradlew -p Android :FolinoLibraryAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL — `LibraryStore.kt`, `LibraryStoreNativeAdapter.kt`, `ScoreRecordWireCodec.kt`, and the regenerated `LibraryAndroidStoreViewModel.kt` (with a `create(store: LibraryStore)` factory) are generated, and `RoomLibraryStore` compiles against them.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoLibraryAndroid/build.gradle.kts \
  Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(android): Room-backed LibraryStore + provided{} codegen wiring"
```

---

## Task 4: Compose + Activity wiring (inject backend, Undo → restore)

Inject `RoomLibraryStore` into the generated ViewModel, and repoint the Snackbar Undo from the removed `insert(row)` to `restore(row.id)`.

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt:146-150`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt:117-126`

- [ ] **Step 1: Inject the Room backend in the ViewModel factory**

In `MainActivity.kt`, the factory must build with a `Context`. Replace the `LibraryVMFactory` object and update its use site.

Replace the object (lines ~146-150):

```kotlin
private class LibraryVMFactory(private val context: android.content.Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        LibraryAndroidStoreViewModel.create(
            store = com.keynumber.folino.library.RoomLibraryStore(context),
        ) as T
}
```

In `LibraryNavGraph`, pass a factory instance built with the app context. Replace the `vm` line (~76):

```kotlin
    val context = LocalContext.current
    val vm: LibraryAndroidStoreViewModel =
        viewModel(factory = LibraryVMFactory(context.applicationContext))
```

Add the import at the top of `MainActivity.kt`:

```kotlin
import androidx.compose.ui.platform.LocalContext
```

- [ ] **Step 2: Repoint Undo to `restore`**

In `LibraryScreen.kt`, in the `onDelete` lambda (lines ~117-126), change the Undo branch from `insert(row)` to `restore(row.id)`:

```kotlin
                        onDelete = {
                            viewModel.delete(row.id)
                            scope.launch {
                                val result = snackbarHost.showSnackbar(
                                    message = context.getString(R.string.library_deleted),
                                    actionLabel = context.getString(R.string.library_undo),
                                )
                                if (result == SnackbarResult.ActionPerformed) viewModel.restore(row.id)
                            }
                        },
```

- [ ] **Step 3: Compile the app module**

Run: `./Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL — `create(store = …)` and `restore(id)` resolve against the regenerated ViewModel.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt \
  Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt
git commit -m "feat(android): inject Room backend + Undo restores soft-deleted row"
```

---

## Task 5: Cross-compile `.so` + end-to-end device smoke

The `@WireletProvided` injection path is device-verified in swift-wirelet's `observable-counter` example, but Folino's two-`.so` app + Room backend + `Double` wire field are new. Validate on the Pixel 8a (per the `feedback_android_install_launch` memory: Android changes are install + launch by Claude).

**Files:** none (build + manual verification).

- [ ] **Step 1: Cross-compile the JNI `.so` with the new types**

Run: `./Scripts/android-build-library-libs.sh`
Expected: `Done. libFolinoLibraryJNI.so + runtime staged under …/jniLibs/{arm64-v8a,x86_64}/`. The rebuilt `.so` now contains the `@_cdecl` bridges for `restore`, the provided `LibraryStore` adapter entry points, and the `ScoreRecordWire` codec.

- [ ] **Step 2: Assemble + install the debug APK**

Run: `./Android/gradlew -p Android :app:installDebug`
Expected: BUILD SUCCESSFUL + `Installed on 1 device`.
(Build order matters: the Gradle codegen reads the `.wirelet-observable-jni.json` / provided sidecars; `installDebug` runs codegen → compile → assemble in the right order. If the device shows `UnsatisfiedLinkError`, rerun Step 1 then Step 2 — the `.so` must be freshly staged before assembly.)

- [ ] **Step 3: Launch the app**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: the Library screen opens.

- [ ] **Step 4: Hand to the user for device verification**

Ask the user to verify on the device (gestures are theirs per repo convention):
1. Import a real `.mscz` → a row appears (title = file name).
2. **Force-quit and relaunch the app → the row is still present** (persistence).
3. Swipe a row left → it disappears + "Score deleted · UNDO" Snackbar → tap UNDO → the row returns.
4. (Optional) `adb shell run-as com.keynumber.folino ls files/Scores` → the `<id>.mscz` file is present and survives the soft-delete.

- [ ] **Step 5: Commit the staged `.so`s**

```bash
git add Android/FolinoLibraryAndroid/src/main/jniLibs
git commit -m "build(android): restage libFolinoLibraryJNI.so with persistence bridges"
```

---

## Self-review notes

- **Spec coverage:** wire types (Task 1) · soft-delete via `deletedAt`/restore (Task 2) · file copy + retention to `filesDir/Scores/<id>.mscz` (Tasks 2–3) · Room backend with no rules (Task 3) · `provided{}` + `providedAdapterPackage` codegen (Task 3) · Undo→restore (Task 4) · device persistence smoke (Task 5) · swift-wirelet v0.3.0 bump (Task 0). Out-of-scope items (Trash screen, prune, real Reader, shared `LibraryStoreCore`) are intentionally absent.
- **Type consistency:** `ScoreRecordWire(id,title,subtitle,composer,localFileName,deletedAt)` and `LibraryStore.{loadAll,upsert,copyImportedFile,removeFile}` are identical across the Swift definition (Task 1), the fake (Task 2), and the Kotlin impl (Task 3). The store API `init(store:)` / `importScore` / `delete` / `restore` matches the tests (Task 2) and the Kotlin call sites (Task 4).
- **Known verification points carried into execution:** (a) the generated Kotlin label for `copyImportedFile(fromPath:…)` (Task 3 Step 3 note); (b) `Double` over the wire — exercised by the device smoke and the host round-trip; (c) Room main-thread query is a documented pilot tradeoff, not a bug.

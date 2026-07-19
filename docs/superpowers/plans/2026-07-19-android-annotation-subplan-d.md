# Android Annotation — Sub-plan D: Shared save policy + Android persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist freehand annotation layers on Android in Room, and lift the annotation save policy (layer assembly, 0.5 s debounce, empty-layer → delete, flush-on-transition, JSON payload codec) into ONE shared, Android-compatible component that BOTH iOS and Android drive — replacing the iOS-only copy in `ReaderViewModel`. Only the UI trigger and the raw blob I/O stay per-platform.

**Architecture (approved — "maximal sharing" ideal):**

```
        ┌──────── AnnotationSaveCoordinator (ReaderAnnotationCore, shared) ────────┐
        │  assemble AnnotationLayer · 0.5s debounce · empty→delete · flush ·        │
        │  AnnotationLayerCodec (JSON {drawings,textBoxes} ⇄ Data)                  │
        └───────────────┬────────────────────────────────────┬────────────────────┘
   iOS trigger ─────────┤                                    ├───────── Android trigger
   (PencilKit didChange, │                                    │   (@WireletObservable bridge,
    via ReaderViewModel) ▼                                    ▼    @WireletExpose from Kotlin)
              AnnotationBlobStore(GRDB)              AnnotationBlobStore(Room via @WireletProvided)
              — dumb blob I/O keyed by scoreID —     — dumb blob I/O keyed by scoreID —
```

The coordinator works against an injected `AnnotationBlobStore` (async, blob-in/out keyed by `ScoreItemID` + `updatedAt`). iOS keeps its `annotation_layers` table (same JSON payload → no migration) but `LiveAnnotationStore` becomes an `AnnotationBlobStore`. Android supplies a Room-backed `AnnotationBlobStore` through the same `@WireletProvided`/`@WireletObservable` mechanism Library uses for `ReaderPreferences`.

**Tech Stack:** Swift 6.3 (`ReaderAnnotationCore` shared; `FolinoReaderJNI` Android bridge), swift-wirelet `@WireFormat`/`@WireletObservable`/`@WireletProvided` (pin `ba1b8e337a508079c5213656e4c01e9edbedc8b4`; Gradle plugin/runtime **0.3.2**), Kotlin/Room 2.6.1 + KSP, Jetpack Compose.

**Source spec:** `docs/superpowers/specs/2026-07-13-android-annotation-design.md`. Parent: `docs/superpowers/plans/2026-07-13-android-annotation-phase2.md` (Sub-plan D). Predecessor: Sub-plan C (`docs/superpowers/plans/2026-07-19-android-annotation-subplan-c.md`) shipped the JNI capture/display bridge; `DrawingAnchorWire` is C's capture output.

## Global Constraints

- **No stored-format change on iOS.** The shared `AnnotationLayerCodec` must encode/decode the SAME `{drawings, textBoxes}` JSON body iOS already stores (round-trip compatible with existing `annotation_layers.payload` blobs) — no DB migration.
- **Save policy is shared, not mirrored.** One implementation of assembly + debounce (0.5 s) + empty→delete + flush; iOS `ReaderViewModel` delegates to it. Never a divergent Kotlin/second Swift copy.
- **Store is dumb.** `AnnotationBlobStore` does raw blob I/O only (`load`/`save`/`delete` by `ScoreItemID`); all policy lives in the coordinator.
- **Android store is Room-backed via `@WireletProvided`** (blob-in/out, synchronous, like `ReaderPreferencesStore`), wrapped into the async `AnnotationBlobStore` seam by a thin adapter.
- **`ReaderAnnotationCore` / `FolinoReaderJNI` carry no SwiftLint plugin** (cross-compiled for Android; host pre-commit lints them).
- **Room DB (pre-release) has no migration history** — a new `@Entity` is a plain add (`fallbackToDestructiveMigration`).
- **swift-wirelet is pinned by revision** `ba1b8e337a508079c5213656e4c01e9edbedc8b4`; Gradle plugin/runtime **0.3.2**.
- **`Domain` is Foundation-only** and compiles for both toolchains.

## Regression de-risk (iOS refactor, Task D3)

The iOS annotation save path is shipped. It is covered by `ReaderTests` (6 annotation suites, incl. `AnnotationAnchoringCoreTests`, `AnnotationAnchoringFormatTests`, `AnnotationUnknownFormatTests`, `InkStrokePencilKitBridgeTests`) + the new `PrefetchedAnchorResolverTests`, plus `Infrastructure` persistence tests. **D3 is done only when all of those stay green AND an iPad device pass confirms draw → persist → reflow → cross-mode is unchanged.** `AnnotationFormatMigrator` (Infrastructure) is NOT touched.

---

## File structure

| File | Responsibility | New? |
|---|---|---|
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationLayerCodec.swift` | JSON `{drawings,textBoxes}` ⇄ `Data`, round-trip-compatible with the iOS payload. | Create |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationBlobStore.swift` | The dumb-store protocol the coordinator injects. | Create |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationSaveCoordinator.swift` | Assembly + debounce + empty→delete + flush + load; the single shared policy. | Create |
| `Packages/Features/Reader/Tests/ReaderTests/AnnotationSaveCoordinatorTests.swift` | Host TDD (fake blob store): debounce coalescing, empty→delete, flush-immediate, load, codec round-trip. | Create |
| `Packages/Infrastructure/Sources/Persistence/LiveAnnotationStore.swift` (+ record) | Conform to `AnnotationBlobStore` (raw payload blob I/O). | Modify |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel+AnnotationPersistence.swift` | Delegate to `AnnotationSaveCoordinator` (drop inline debounce/pending). | Modify |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` | Hold a coordinator instead of raw store; wire trigger + flush. | Modify |
| `App/AppBootstrap.swift` (+ `AppShellView.swift`) | Construct the coordinator from `LiveAnnotationStore`. | Modify |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationPersistenceStore.swift` | `@WireletProvided` blob store protocol (Kotlin-implemented). | Create |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationSaveBridge.swift` | `@WireletObservable` bridge wrapping the coordinator; `@WireletExpose` trigger/flush/load; the sync→async store adapter. | Create |
| `Packages/Features/Reader/Package.swift` | Add `WireletObservable`/`WireletProvided` products + `WireletObservableBridges`/`WireletProvidedBridges` plugins to `FolinoReaderJNI`. | Modify |
| `Android/FolinoReaderAndroid/build.gradle.kts` | wirelet Gradle codegen (0.3.2: codecs + provided + observable) + Room 2.6.1 + KSP. | Modify |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../RoomAnnotationStore.kt` (+ entity/DAO + DB reg) | Room `annotation_layers` + the `@WireletProvided` impl. | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../AnnotationSaveController.kt` | Construct the generated `AnnotationSaveBridgeViewModel(RoomAnnotationStore(...))`. | Create |

---

## Task D1: `AnnotationLayerCodec` (shared JSON, iOS-compatible)

**Files:** Create `.../ReaderAnnotationCore/AnnotationLayerCodec.swift`; test in `AnnotationSaveCoordinatorTests.swift` (create the file here, reuse across D1/D2).

**Interface produced:**
```swift
public enum AnnotationLayerCodec {
    public static func encode(drawings: [DrawingAnchor], textBoxes: [TextBoxAnchor]) -> Data
    public static func decode(_ data: Data) -> (drawings: [DrawingAnchor], textBoxes: [TextBoxAnchor])?
}
```

- [ ] **Step 1: Failing test** — round-trip + shape lock (keys `drawings`/`textBoxes`):

```swift
@Test func layerCodecRoundTrips() throws {
    let d = DrawingAnchor(kind: .musical(MusicalAnchor(measureIndex: 1, tickInMeasure: 0, partIndex: 0,
        staffIndexInPart: 0, dxSp: 0.5, verticalOffsetSp: -1)),
        encodedDrawing: Data([0x46, 0x49, 0x4E, 0x4B]))
    let bytes = AnnotationLayerCodec.encode(drawings: [d], textBoxes: [])
    let json = try #require(String(data: bytes, encoding: .utf8))
    #expect(json.contains("\"drawings\"") && json.contains("\"textBoxes\""))
    let back = try #require(AnnotationLayerCodec.decode(bytes))
    #expect(back.drawings == [d]); #expect(back.textBoxes.isEmpty)
    #expect(AnnotationLayerCodec.decode(Data([0x00, 0x01])) == nil) // garbage → nil
}
```

- [ ] **Step 2: Run — FAIL** (`AnnotationLayerCodec` undefined). Command:
  `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationSaveCoordinatorTests` (Swift Testing filters by **type name**, not the `@Suite` display string).
- [ ] **Step 3: Implement** — a private `Body: Codable { var drawings: [DrawingAnchor]; var textBoxes: [TextBoxAnchor] }`; `encode` = `(try? JSONEncoder().encode(Body(...))) ?? Data()`; `decode` = `try? JSONDecoder().decode(Body.self, from:)` mapped to the tuple. Keys default to `drawings`/`textBoxes` — matches the existing iOS `AnnotationLayerRecord` body.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(reader): shared AnnotationLayerCodec (iOS-compatible {drawings,textBoxes} JSON)`.

---

## Task D2: `AnnotationBlobStore` + `AnnotationSaveCoordinator`

**Files:** Create `AnnotationBlobStore.swift`, `AnnotationSaveCoordinator.swift`; extend `AnnotationSaveCoordinatorTests.swift`.

**Interfaces produced:**
```swift
public protocol AnnotationBlobStore: Sendable {
    func load(scoreID: ScoreItemID) async throws -> Data?          // raw payload blob
    func save(scoreID: ScoreItemID, updatedAt: Date, payload: Data) async throws
    func delete(scoreID: ScoreItemID) async throws
}

public actor AnnotationSaveCoordinator {
    public init(store: any AnnotationBlobStore, debounce: Duration = .seconds(0.5), now: @Sendable @escaping () -> Date = { Date() })
    public func load(scoreID: ScoreItemID) async -> [DrawingAnchor]      // [] on miss/error
    public func drawingsDidChange(_ drawings: [DrawingAnchor], scoreID: ScoreItemID) // arms debounce
    public func flush() async                                            // write pending now (score-swap/teardown)
}
```

The actor owns: `pending: (scoreID, [DrawingAnchor])?`, a `saveTask: Task<Void, Never>?`. `drawingsDidChange` snapshots pending, cancels+rearms a `Task { try? await Task.sleep(for: debounce); if Task.isCancelled { return }; await persist() }`. `persist` clears pending up front, then `drawings.isEmpty ? store.delete : store.save(payload: AnnotationLayerCodec.encode(...))`. `flush` cancels the task and persists immediately. Injectable `debounce`/`now` make it deterministic to test (pass `.zero`/`.milliseconds(1)` in tests).

- [ ] **Step 1: Failing tests** (fake store recording calls):

```swift
final class FakeBlobStore: AnnotationBlobStore, @unchecked Sendable {
    var saved: [(ScoreItemID, Data)] = []; var deleted: [ScoreItemID] = []; var stored: [ScoreItemID: Data] = [:]
    func load(scoreID: ScoreItemID) async throws -> Data? { stored[scoreID] }
    func save(scoreID: ScoreItemID, updatedAt: Date, payload: Data) async throws { saved.append((scoreID, payload)); stored[scoreID] = payload }
    func delete(scoreID: ScoreItemID) async throws { deleted.append(scoreID); stored[scoreID] = nil }
}

@Test func debounceCoalescesRapidChangesIntoOneSave() async throws {
    let store = FakeBlobStore()
    let c = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(20))
    let id = ScoreItemID(...); let s = /* a DrawingAnchor */
    c.drawingsDidChange([s], scoreID: id); c.drawingsDidChange([s, s2], scoreID: id) // rapid
    try await Task.sleep(for: .milliseconds(60))
    #expect(store.saved.count == 1)                     // coalesced
    #expect(AnnotationLayerCodec.decode(store.saved[0].1)?.drawings.count == 2) // last wins
}

@Test func emptyDrawingsDeletes() async throws { /* didChange([]) → after debounce, store.deleted == [id] */ }
@Test func flushWritesImmediatelyWithoutWaiting() async throws { /* didChange then flush() → saved before debounce elapses */ }
@Test func loadDecodesStoredPayload() async throws { /* preload store, load(id) returns the drawings */ }
```

- [ ] **Step 2: Run — FAIL.**  **Step 3: Implement** the protocol + actor as specified.  **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(reader): shared AnnotationSaveCoordinator (assembly + debounce + empty→delete + flush)`.

---

## Task D3: iOS delegates to the coordinator (regression-gated)

**Files:** Modify `LiveAnnotationStore.swift` (+ `AnnotationLayerRecord.swift`), `ReaderViewModel+AnnotationPersistence.swift`, `ReaderViewModel.swift`, `App/AppBootstrap.swift`, `AppShellView.swift`.

- [ ] **Step 1:** `LiveAnnotationStore: AnnotationBlobStore` — `save(scoreID:updatedAt:payload:)` upserts a record whose `payload` column = `payload` verbatim (no re-encode), `updated_at` = `updatedAt`, `id` = a stable per-score id; `load` returns the `payload` column bytes; `delete` by `score_item_id`. Keep the table/columns unchanged. Retire the `AnnotationLayer`-typed `AnnotationStore` methods (or keep as a thin shim if other callers exist — grep first).
- [ ] **Step 2:** `ReaderViewModel` holds `annotationCoordinator: AnnotationSaveCoordinator` (injected). `annotationDrawingsDidChange(_:)` → `recordAnnotationStroke` gate (unchanged) then `annotationCoordinator.drawingsDidChange(drawings, scoreID: scoreItem.id)`. `flushPendingAnnotationSave()` → `await annotationCoordinator.flush()`. `loadAnnotations()` → `annotationDrawings = await annotationCoordinator.load(scoreID: scoreItem.id)`. Delete the inline `annotationSaveTask`/`pendingAnnotationDrawings`/`persistPendingAnnotation`.
- [ ] **Step 3:** `AppBootstrap`/`AppShellView` construct `AnnotationSaveCoordinator(store: LiveAnnotationStore(database:))` and inject it into `ReaderViewModel`.
- [ ] **Step 4: Regression gate** — run the FULL Reader annotation test set + Infrastructure persistence tests:
  `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests` and the Infrastructure package tests. Expected: all green (incl. the 6 pre-existing annotation suites). Then **device pass** (iPad): draw → background/return persists → reflow follows → cross-mode intact.
- [ ] **Step 5: Commit** — `refactor(reader): route iOS annotation save through the shared AnnotationSaveCoordinator` (only after green + device pass).

---

## Task D4: Android Swift — `@WireletProvided` store + `@WireletObservable` bridge

**Files:** Create `AnnotationPersistenceStore.swift`, `AnnotationSaveBridge.swift`; modify `Reader/Package.swift`.

- [ ] **Step 1: Package.swift** — add to the `FolinoReaderJNI` target (Android branch): products `.product(name: "WireletObservable", package: "swift-wirelet")`, `.product(name: "WireletProvided", package: "swift-wirelet")`; plugins `.plugin(name: "WireletObservableBridges", package: "swift-wirelet")`, `.plugin(name: "WireletProvidedBridges", package: "swift-wirelet")`.
- [ ] **Step 2: `AnnotationPersistenceStore.swift`** — the Kotlin-backed store, blob-in/out (sync, like `ReaderPreferencesStore`):

```swift
import WireletProvided
@WireletProvided
public protocol AnnotationPersistenceStore {
    func loadBytes(scoreId: String) -> Data      // empty Data = no layer
    func saveBytes(scoreId: String, updatedAtMillis: Int64, bytes: Data)
    func delete(scoreId: String)
}
```

- [ ] **Step 3: `AnnotationSaveBridge.swift`** — `@WireletObservable @Observable public final class AnnotationSaveBridge`. Ctor `public init(store: AnnotationPersistenceStore)` builds a `WireletBackedBlobStore` adapter (conforms `AnnotationBlobStore`, maps async→the sync provided calls; `ScoreItemID(scoreId)` ↔ `String`, `Date`↔`Int64` millis) and an `AnnotationSaveCoordinator(store:)`. `@WireletExpose` methods Kotlin calls: `open(scoreId:)` (→ `load`, publishes the decoded drawings via a `state` wire if the overlay reads them; for D the overlay is E, so `open` may just prime the store), `drawingsChanged(_ wires: [DrawingAnchorWire])` (rebuild `[DrawingAnchor]`, → `coordinator.drawingsDidChange`), `flush()`. Reuse `DrawingAnchorWire` (Sub-plan C) as the Kotlin→Swift drawing payload. No `state` StateFlow is required for D unless E needs it — keep the bridge write-only for now (document that E adds the read/observe path).
- [ ] **Step 4: Cross-build** — `folino-reader-crossbuild.sh <Reader pkg>` (arm64). Expected: `libFolinoReaderJNI.so` links; jextract + the wirelet bridge plugins run clean. Fix the Android CGFloat/CGPoint shim if any new geometry use appears (`#if !canImport(CoreGraphics) typealias … = ReaderAnnotationCore.…`).
- [ ] **Step 5: Commit** — `feat(reader): @WireletProvided AnnotationPersistenceStore + @WireletObservable AnnotationSaveBridge (Android)`.

---

## Task D5: Android Kotlin/Gradle — wirelet codegen + Room store

**Files:** Modify `FolinoReaderAndroid/build.gradle.kts`; create `RoomAnnotationStore.kt` (+ entity/DAO + DB registration), `AnnotationSaveController.kt`.

- [ ] **Step 1: `build.gradle.kts`** — apply `id("io.github.jiyimeta.wirelet") version "0.3.2"` + `id("com.google.devtools.ksp") version "2.0.20-1.0.25"`; deps `api("io.github.jiyimeta:wirelet-runtime:0.3.2")`, `api("io.github.jiyimeta:wirelet-observable-runtime:0.3.2")`, `implementation("androidx.room:room-runtime:2.6.1")`, `ksp("androidx.room:room-compiler:2.6.1")`. Add the `wirelet { sources/observable/provided { register("main") { schemaPaths → Packages/Features/Reader/Sources/FolinoReaderJNI; packages → com.keynumber.folino.reader; libraryName "FolinoReaderJNI" } } }` block + the `generateWireletCodecsMain`/`...ViewModelsMain`/`...ProvidedInterfacesMain` src-dir + `dependsOn` wiring — mirror `FolinoLibraryAndroid/build.gradle.kts` verbatim, swapping package/paths to Reader.
- [ ] **Step 2: Room** — `@Entity(tableName = "annotation_layers") data class AnnotationLayerEntity(@PrimaryKey @ColumnInfo("score_id") val scoreId: String, @ColumnInfo("updated_at") val updatedAt: Long, val payload: ByteArray)`; `@Dao AnnotationLayerDao { load/upsert(REPLACE)/delete }`. Register in an annotation Room DB (own `@Database` in FolinoReaderAndroid, `version = 1`, `fallbackToDestructiveMigration`, `folino-reader.db`) — Reader owns no Room today, so a small Reader-local DB keeps the module boundary clean (no FolinoLibraryAndroid ↔ Reader coupling).
- [ ] **Step 3: `RoomAnnotationStore.kt`** — `class RoomAnnotationStore(context) : AnnotationPersistenceStore` (the generated `@WireletProvided` interface): `loadBytes` → dao.load(scoreId) ?: ByteArray(0); `saveBytes` → dao.upsert(entity); `delete` → dao.delete(scoreId).
- [ ] **Step 4: `AnnotationSaveController.kt`** — `AnnotationSaveBridgeViewModel.create(RoomAnnotationStore(context))` (generated VM), exposing `drawingsChanged`/`flush` for Sub-plan E's ink overlay to call.
- [ ] **Step 5: Build** — stage the `.so` + java-generated (`Scripts/android-build-reader-libs.sh`), then `./gradlew :FolinoReaderAndroid:compileDebugKotlin` (or `assembleDebug`). Compiles against the CURRENT mavenLocal ssm SNAPSHOT (the new ssm anchor JNI is a RUNTIME dep for Sub-plan E, not needed to compile D). Expected: wirelet Kotlin codecs for `DrawingAnchorWire`/`StrokeTransformWire`/`PointMmWire` + the provided/observable adapters generate; Kotlin compiles.
- [ ] **Step 6: Commit** — `feat(reader-android): Room annotation_layers store + wirelet codegen wiring for the save bridge`.

---

## Task D6: Verification wrap-up

- [ ] iOS: `ReaderTests` (all) + Infrastructure persistence tests green; iPad device pass (D3 gate).
- [ ] Android: `libFolinoReaderJNI.so` cross-build green (D4); `:FolinoReaderAndroid` Kotlin compiles (D5).
- [ ] **Deferred to Sub-plan E:** the emulator round-trip (draw → capture → store → relaunch → load → render) — needs the ink overlay (E) + the ssm mavenLocal republish (so `SheetMusicJNI.nativeResolveAnchor` is present at runtime). Note this in the completion report; do NOT claim end-to-end persistence verified until E.

## Self-review

- **Spec coverage:** Room `annotation_layers` 1:1 (D5) · `@WireletProvided` store like `ReaderPreferencesStore` (D2 seam + D4 protocol + D5 impl) · save policy in shared Swift mirroring `ReaderViewModel+AnnotationPersistence` — here *unified*, not mirrored (D2 coordinator + D3 iOS delegation) · reached from Kotlin via `@WireletObservable` bridge (D4).
- **Type consistency:** `AnnotationBlobStore` (async) is the coordinator seam on both platforms; iOS `LiveAnnotationStore` conforms directly, Android via the sync→async adapter over `@WireletProvided AnnotationPersistenceStore`. `DrawingAnchorWire` (C) is the Kotlin→Swift drawing payload. Payload bytes = `AnnotationLayerCodec` JSON = the existing iOS blob shape (no migration).
- **No placeholders:** D1/D2 carry full test + impl; D3–D5 carry exact signatures, file lists, and the Library template to copy. The one area to confirm at execution: whether any non-Reader caller still needs the old `AnnotationStore` protocol (grep in D3 Step 1) — keep a shim if so.

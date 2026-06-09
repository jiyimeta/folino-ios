# Android Edit Score Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "edit score info" feature to the Android app, reachable from both Library (per-score `⋮` overflow) and Reader (top app bar info icon), as a Material full-screen edit screen, sharing all edit logic with iOS.

**Architecture:** Lift the editable-fields value type, the prefill rule, and the save normalization into `Domain` (Foundation-only) so iOS and the Android-gated Swift `LibraryAndroidStore` call the same code. Persistence rides the existing swift-wirelet bridge: a new void mutator `saveScoreInfo` and a synchronous getter `scoreInfoForEditing`. The Compose UI is a full-screen destination in the app module reachable as its own nav route from both surfaces; the Reader module stays decoupled via a callback.

**Tech Stack:** Swift 6.3 (Domain + FolinoLibraryJNI), swift-wirelet JNI codegen, Kotlin/Jetpack Compose (Material3), Room, swift-sheet-music (`MSCZReader`).

---

## File Structure

**Swift / shared (iOS + Android):**
- Move: `Packages/ScoreUI/Sources/ScoreUI/EditableScoreInfo.swift` → `Packages/Domain/Sources/Domain/Models/EditableScoreInfo.swift` (add `prefilled(...)` + `normalized()`)
- Create: `Packages/Domain/Tests/DomainTests/EditableScoreInfoTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (saveMetadata uses `normalized()`)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (saveMetadata uses `normalized()`)
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift` (3 nullable credit fields)
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` (`saveScoreInfo`, `scoreInfoForEditing`)
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/EditScoreInfoWire.swift` (`@WireFormat` return type)

**Android (Kotlin/Compose):**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` (entity, mapping, DB version, migration)
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/scoreinfo/EditScoreInfoScreen.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (nav route, Library overflow wiring, Reader wiring)
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt` (overflow "Edit info" item + callback plumbing)
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (info icon + `onEditInfo` param)
- Modify: `Android/app/src/main/res/values/strings.xml` (new keys)
- Modify: `Android/FolinoReaderAndroid/src/main/res/values/strings.xml` (info-icon content description)

---

## Conventions & commands used in this plan

- **Swift package test (SwiftLint plugin breaks `swift test`):**
  `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
  (If the `Domain` scheme is not found, use `-scheme Domain-Package`.)
- **iOS app build:**
  `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
- **Android library codegen + `.so` (regenerate after editing any `@WireFormat` / `@WireletExpose`):**
  `Scripts/android-build-library-libs.sh`
  (This runs the gradle `generateWireletCodecsMain` / `generateWireletObservableViewModelsMain` tasks and cross-compiles the `.so`. Follow the repo's Android build memory for the exact toolchain PATH; a fresh worktree must also run `Scripts/android-build-libs.sh` first to generate jextract bindings.)
- **Android app install + launch (Pixel):**
  `./gradlew :app:installDebug` (run with cwd `Android/`), then
  `adb shell am start -n com.keynumber.folino/.MainActivity`
- Per CLAUDE.md: stage **whole files** only; the pre-commit hook fixes/re-stages Swift. No `git add -p`.

---

## Phase A — Shared Domain logic (TDD)

### Task 1: Lift `EditableScoreInfo` into Domain with `prefilled` + `normalized`

**Files:**
- Move: `Packages/ScoreUI/Sources/ScoreUI/EditableScoreInfo.swift` → `Packages/Domain/Sources/Domain/Models/EditableScoreInfo.swift`
- Test: `Packages/Domain/Tests/DomainTests/EditableScoreInfoTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/EditableScoreInfoTests.swift`:

```swift
import Testing
@testable import Domain

@Suite struct EditableScoreInfoTests {
    @Test func prefillStoredValueWinsOverFileMetadata() {
        let meta = ScoreFileMetadata(source: .unknown, composer: "File", arranger: "FileArr",
                                     lyricist: "FileLyr", copyright: "FileCopy")
        let info = EditableScoreInfo.prefilled(
            title: "T", subtitle: "Sub", composer: "Stored",
            arranger: nil, lyricist: "", copyright: nil, fileMetadata: meta)
        #expect(info.composer == "Stored")          // stored non-nil wins
        #expect(info.arranger == "FileArr")          // nil falls back to file
        #expect(info.lyricist == "")                 // explicit "" suppresses fallback
        #expect(info.copyright == "FileCopy")        // nil falls back to file
        #expect(info.subtitle == "Sub")              // subtitle never falls back
    }

    @Test func prefillSubtitleHasNoFileFallback() {
        let meta = ScoreFileMetadata(source: .unknown, composer: nil, arranger: nil,
                                     lyricist: nil, copyright: nil)
        let info = EditableScoreInfo.prefilled(
            title: "T", subtitle: nil, composer: nil,
            arranger: nil, lyricist: nil, copyright: nil, fileMetadata: meta)
        #expect(info.subtitle == "")
    }

    @Test func normalizedTrimsAllFields() {
        let info = EditableScoreInfo(title: "  T  ", subtitle: " s ", composer: " c ",
                                     arranger: " a ", lyricist: " l ", copyright: " r ")
        let n = info.normalized()
        #expect(n?.title == "T")
        #expect(n?.subtitle == "s")
        #expect(n?.composer == "c")
        #expect(n?.arranger == "a")
        #expect(n?.lyricist == "l")
        #expect(n?.copyright == "r")
    }

    @Test func normalizedReturnsNilWhenTitleBlank() {
        let info = EditableScoreInfo(title: "   ", subtitle: "x", composer: "",
                                     arranger: "", lyricist: "", copyright: "")
        #expect(info.normalized() == nil)
    }

    @Test func normalizedKeepsClearedFieldsAsEmptyString() {
        let info = EditableScoreInfo(title: "T", subtitle: "", composer: "",
                                     arranger: "", lyricist: "", copyright: "")
        let n = info.normalized()
        #expect(n?.composer == "")   // empty stays "", a meaningful "cleared" value
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/EditableScoreInfoTests`
Expected: FAIL — `EditableScoreInfo` not found in `Domain` (it's still in ScoreUI), `prefilled`/`normalized` undefined.

- [ ] **Step 3: Move the type and add the new API**

Delete `Packages/ScoreUI/Sources/ScoreUI/EditableScoreInfo.swift` and create
`Packages/Domain/Sources/Domain/Models/EditableScoreInfo.swift`:

```swift
import Foundation

/// Mutable form payload for the edit-info screen. Empty strings are meaningful — saving an empty field clears it
/// (persisted as `""`, which suppresses future file pre-fill).
public struct EditableScoreInfo: Equatable {
    public var title: String
    public var subtitle: String
    public var composer: String
    public var arranger: String
    public var lyricist: String
    public var copyright: String

    public init(
        title: String,
        subtitle: String,
        composer: String,
        arranger: String,
        lyricist: String,
        copyright: String,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
    }

    /// Build the screen's initial field values from a stored `ScoreItem` plus optional on-disk metaTags.
    public init(item: ScoreItem, fileMetadata: ScoreFileMetadata?) {
        self = EditableScoreInfo.prefilled(
            title: item.title,
            subtitle: item.subtitle,
            composer: item.composer,
            arranger: item.arranger,
            lyricist: item.lyricist,
            copyright: item.copyright,
            fileMetadata: fileMetadata,
        )
    }

    /// The single shared pre-fill rule (iOS + Android call this). For each optional credit field a stored value
    /// (including an explicit empty string the user previously saved) wins; only `nil` falls back to the file's metaTag.
    /// Subtitle is not a metaTag, so it never falls back.
    public static func prefilled(
        title: String,
        subtitle: String?,
        composer: String?,
        arranger: String?,
        lyricist: String?,
        copyright: String?,
        fileMetadata: ScoreFileMetadata?,
    ) -> EditableScoreInfo {
        EditableScoreInfo(
            title: title,
            subtitle: subtitle ?? "",
            composer: composer ?? fileMetadata?.composer ?? "",
            arranger: arranger ?? fileMetadata?.arranger ?? "",
            lyricist: lyricist ?? fileMetadata?.lyricist ?? "",
            copyright: copyright ?? fileMetadata?.copyright ?? "",
        )
    }

    /// Trim every field on whitespace/newlines. Returns `nil` when the trimmed title is empty (title is required);
    /// other fields keep their trimmed value, with empties preserved as `""` (an explicit "cleared" value).
    public func normalized() -> EditableScoreInfo? {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let t = trim(title)
        guard !t.isEmpty else { return nil }
        return EditableScoreInfo(
            title: t,
            subtitle: trim(subtitle),
            composer: trim(composer),
            arranger: trim(arranger),
            lyricist: trim(lyricist),
            copyright: trim(copyright),
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/EditableScoreInfoTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/EditableScoreInfo.swift \
        Packages/Domain/Tests/DomainTests/EditableScoreInfoTests.swift \
        Packages/ScoreUI/Sources/ScoreUI/EditableScoreInfo.swift
git commit -m "feat(domain): lift EditableScoreInfo with shared prefill+normalize"
```

---

### Task 2: Point iOS save paths at the shared `normalized()`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift:94-105`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (its `saveMetadata`)
- Modify (imports only if needed): `Packages/ScoreUI/Sources/ScoreUI/ScoreInfoEditing.swift`, `Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift`

- [ ] **Step 1: Replace `LibraryViewModel.saveMetadata` body**

In `LibraryViewModel.swift`, replace lines 94-105 (the current `saveMetadata`) with:

```swift
    /// Apply the edited fields to the item and persist. Title is required; all fields are trimmed and empties stored
    /// as `""`. Trim/validation is the shared `EditableScoreInfo.normalized()` rule (iOS + Android).
    public func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        guard let n = fields.normalized() else { return }
        var updated = item
        updated.title = n.title
        updated.subtitle = n.subtitle
        updated.composer = n.composer
        updated.arranger = n.arranger
        updated.lyricist = n.lyricist
        updated.copyright = n.copyright
        await save(updated)
    }
```

- [ ] **Step 2: Replace `ReaderViewModel.saveMetadata` body**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, find its `saveMetadata(_:fields:)` (the `ScoreInfoEditing` conformance — same trim/title/empty logic as Library), and replace its body with the identical shape:

```swift
    public func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
        guard let n = fields.normalized() else { return }
        var updated = item
        updated.title = n.title
        updated.subtitle = n.subtitle
        updated.composer = n.composer
        updated.arranger = n.arranger
        updated.lyricist = n.lyricist
        updated.copyright = n.copyright
        await save(updated)
        // Keep any existing in-memory scoreItem update that followed the old save call — preserve those lines.
    }
```

> Note: if the Reader version also mutates an in-memory `scoreItem`/published state after saving, keep that follow-on code; only the trim/validate block changes.

- [ ] **Step 3: Ensure `import Domain` where `EditableScoreInfo` is referenced**

`EditableScoreInfo` now lives in `Domain`. Confirm these files `import Domain` (add it if missing):
- `Packages/ScoreUI/Sources/ScoreUI/ScoreInfoEditing.swift` (already imports Domain)
- `Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift`

Run: `grep -n "import Domain" Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift`
If absent, add `import Domain` at the top.

- [ ] **Step 4: Build the iOS app to verify the refactor compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift
git commit -m "refactor: iOS save paths use shared EditableScoreInfo.normalized"
```

---

## Phase B — Android persistence bridge

### Task 3: Add nullable credit columns to the persistence projection

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift:13-40`
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` (entity 17-26, loadAll 185-188, upsert 190-202, DB 140-155, + migration)

- [ ] **Step 1: Add the three fields to the Swift wire struct**

In `ScoreRecordWire.swift`, replace the struct (lines 13-40) with (new fields are nullable so `NULL` = "never edited", `""` = "cleared"):

```swift
@WireFormat
public struct ScoreRecordWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var arranger: String?
    public var lyricist: String?
    public var copyright: String?
    public var localFileName: String // "<id>.mscz" — built in Swift, iOS naming convention
    public var deletedAt: Double // 0 == live; >0 == soft-deleted at that Unix time
    public var isFavorite: Bool // mirrors iOS ScoreItem.isFavorite

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        arranger: String? = nil,
        lyricist: String? = nil,
        copyright: String? = nil,
        localFileName: String,
        deletedAt: Double,
        isFavorite: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
        self.localFileName = localFileName
        self.deletedAt = deletedAt
        self.isFavorite = isFavorite
    }
}
```

- [ ] **Step 2: Regenerate the Kotlin codec**

Run: `Scripts/android-build-library-libs.sh`
Expected: gradle regenerates `ScoreRecordWire.kt` with the three new nullable fields. (Build the `.so` too so later JNI calls link.)

- [ ] **Step 3: Add the columns to the Room entity**

In `RoomLibraryStore.kt`, replace `ScoreRecordEntity` (lines 17-26):

```kotlin
@Entity(tableName = "score_records")
data class ScoreRecordEntity(
    @PrimaryKey val id: String,
    val title: String,
    val subtitle: String,
    val composer: String,
    val arranger: String? = null,
    val lyricist: String? = null,
    val copyright: String? = null,
    @ColumnInfo(name = "local_file_name") val localFileName: String,
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean = false,
)
```

- [ ] **Step 4: Update the entity↔wire mapping**

In `RoomLibraryStore.kt`, replace `loadAll` (lines 185-188) and `upsert` (190-202):

```kotlin
override fun loadAll(): List<ScoreRecordWire> =
    dao.loadAll().map {
        ScoreRecordWire(
            it.id, it.title, it.subtitle, it.composer,
            it.arranger, it.lyricist, it.copyright,
            it.localFileName, it.deletedAt, it.isFavorite,
        )
    }

override fun upsert(record: ScoreRecordWire) {
    dao.upsert(
        ScoreRecordEntity(
            id = record.id,
            title = record.title,
            subtitle = record.subtitle,
            composer = record.composer,
            arranger = record.arranger,
            lyricist = record.lyricist,
            copyright = record.copyright,
            localFileName = record.localFileName,
            deletedAt = record.deletedAt,
            isFavorite = record.isFavorite,
        ),
    )
}
```

> If the generated Kotlin `ScoreRecordWire` orders the new fields differently than the positional `loadAll` call above, switch that call to named arguments to match the generated constructor.

- [ ] **Step 5: Bump the Room version and add the migration**

In `RoomLibraryStore.kt`, change the `@Database` `version = 1` (line ~150) to `version = 2`. Then add a migration object near the database declaration:

```kotlin
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE score_records ADD COLUMN arranger TEXT")
        db.execSQL("ALTER TABLE score_records ADD COLUMN lyricist TEXT")
        db.execSQL("ALTER TABLE score_records ADD COLUMN copyright TEXT")
    }
}
```

Find the `Room.databaseBuilder(...)` call in this file and add `.addMigrations(MIGRATION_1_2)` to the builder chain. Add the imports `androidx.room.migration.Migration` and `androidx.sqlite.db.SupportSQLiteDatabase` if not present.

Run: `grep -n "databaseBuilder" Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`
to locate the builder for the edit.

- [ ] **Step 6: Build the Android library to verify schema + codec compile**

Run: `Scripts/android-build-library-libs.sh`
Expected: build succeeds; no Room schema/migration compile error.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift \
        Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(android): persist arranger/lyricist/copyright (Room v2)"
```

---

### Task 4: Expose `saveScoreInfo` over the wirelet bridge

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` (add near `favorite`, ~line 128)

- [ ] **Step 1: Add the `saveScoreInfo` mutator**

In `LibraryAndroidStore.swift`, after the `unfavorite`/`setFavorite` block, add:

```swift
/// Persist edited credit fields for a score. Title is required; all fields are trimmed and empties stored as `""`
/// (an explicit "cleared" value). Uses the shared `EditableScoreInfo.normalized()` rule (iOS parity). No-op on blank
/// title or unknown id.
@WireletExpose
public func saveScoreInfo(
    _ id: String,
    _ title: String,
    _ subtitle: String,
    _ composer: String,
    _ arranger: String,
    _ lyricist: String,
    _ copyright: String,
) {
    let fields = EditableScoreInfo(
        title: title, subtitle: subtitle, composer: composer,
        arranger: arranger, lyricist: lyricist, copyright: copyright,
    )
    guard let n = fields.normalized() else { return }
    var all = store.loadAll()
    guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
    all[idx].title = n.title
    all[idx].subtitle = n.subtitle
    all[idx].composer = n.composer
    all[idx].arranger = n.arranger        // "" suppresses future file pre-fill
    all[idx].lyricist = n.lyricist
    all[idx].copyright = n.copyright
    store.upsert(all[idx])
    reload(using: all)
}
```

Confirm `import Domain` is present at the top of `LibraryAndroidStore.swift` (it is, for `ScoreShareFormat`). `EditableScoreInfo` now resolves from `Domain`.

- [ ] **Step 2: Regenerate the bridge and verify the generated method**

Run: `Scripts/android-build-library-libs.sh`
Then: `grep -n "saveScoreInfo" Android/FolinoLibraryAndroid/build/generated/java/generateWireletObservableViewModelsMain/com/keynumber/folino/library/generated/LibraryAndroidStoreViewModel.kt`
Expected: a generated method like
`fun saveScoreInfo(id: String, title: String, subtitle: String, composer: String, arranger: String, lyricist: String, copyright: String) = nativeSaveScoreInfo(nativePtr, id, title, subtitle, composer, arranger, lyricist, copyright)`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(android): wirelet saveScoreInfo bridge"
```

---

### Task 5: Expose `scoreInfoForEditing` (synchronous prefill getter)

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/EditScoreInfoWire.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`

- [ ] **Step 1: Define the return wire struct**

Create `Packages/Features/Library/Sources/FolinoLibraryJNI/EditScoreInfoWire.swift`:

```swift
import WireletRuntime

/// Snapshot the Android edit-info screen loads to pre-fill its fields plus read-only info.
/// `source` is a display label ("MuseScore 4" / "MusicXML" / "MIDI" / "PDF") or `""` when unknown.
/// `addedAt` is Unix seconds (0 when unavailable).
@WireFormat
public struct EditScoreInfoWire: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var composer: String
    public var arranger: String
    public var lyricist: String
    public var copyright: String
    public var source: String
    public var addedAt: Double

    public init(
        title: String, subtitle: String, composer: String, arranger: String,
        lyricist: String, copyright: String, source: String, addedAt: Double,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
        self.source = source
        self.addedAt = addedAt
    }
}
```

> Match the `@WireFormat` import used by the existing `ScoreRecordWire.swift` — if that file imports the wirelet macro module under a different name, use the same import here.

- [ ] **Step 2: Add the synchronous getter (stored values only in this task)**

In `LibraryAndroidStore.swift`, add (mirrors the export sync-return pattern at lines 292-303). File-metaTag pre-fill and the real `source` label are added in Task 11; here `fileMetadata` is `nil` and `source` is `""`:

```swift
/// Pre-filled fields + read-only info for the edit-info screen. Stored values only here (Task 11 adds file-metaTag
/// fallback + the parsed source label). `addedAt` comes from the score file's creation date.
@WireletExpose
public func scoreInfoForEditing(_ id: String) -> EditScoreInfoWire {
    guard let record = store.loadAll().first(where: { $0.id == id }) else {
        return EditScoreInfoWire(title: "", subtitle: "", composer: "", arranger: "",
                                 lyricist: "", copyright: "", source: "", addedAt: 0)
    }
    let prefill = EditableScoreInfo.prefilled(
        title: record.title, subtitle: record.subtitle, composer: record.composer,
        arranger: record.arranger, lyricist: record.lyricist, copyright: record.copyright,
        fileMetadata: nil,
    )
    let path = "\(store.scoresDirectoryPath())/\(record.localFileName)"
    let addedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)?
        .timeIntervalSince1970 ?? 0
    return EditScoreInfoWire(
        title: prefill.title, subtitle: prefill.subtitle, composer: prefill.composer,
        arranger: prefill.arranger, lyricist: prefill.lyricist, copyright: prefill.copyright,
        source: "", addedAt: addedAt,
    )
}
```

Add `import Foundation` at the top of `LibraryAndroidStore.swift` if not already present (for `FileManager`).

- [ ] **Step 3: Regenerate and verify the generated getter**

Run: `Scripts/android-build-library-libs.sh`
Then: `grep -n "scoreInfoForEditing" Android/FolinoLibraryAndroid/build/generated/java/generateWireletObservableViewModelsMain/com/keynumber/folino/library/generated/LibraryAndroidStoreViewModel.kt`
Expected: a generated getter that decodes the wire, e.g.
`fun scoreInfoForEditing(id: String): EditScoreInfoWire = EditScoreInfoWireCodec.decodePayload(nativeScoreInfoForEditing(nativePtr, id))`
(exact decode shape matches the export `exportFormats` precedent).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/EditScoreInfoWire.swift \
        Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(android): wirelet scoreInfoForEditing getter"
```

---

## Phase C — Android UI

### Task 6: Add string resources

**Files:**
- Modify: `Android/app/src/main/res/values/strings.xml`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values/strings.xml`

- [ ] **Step 1: Add app-module strings**

In `Android/app/src/main/res/values/strings.xml`, add inside `<resources>`:

```xml
<string name="edit_info">Edit info</string>
<string name="edit_info_save">Save</string>
<string name="edit_info_section_credits">Credits</string>
<string name="edit_info_section_info">Info</string>
<string name="edit_info_field_title">Title</string>
<string name="edit_info_field_subtitle">Subtitle</string>
<string name="edit_info_field_composer">Composer</string>
<string name="edit_info_field_arranger">Arranger</string>
<string name="edit_info_field_lyricist">Lyricist</string>
<string name="edit_info_field_copyright">Copyright</string>
<string name="edit_info_info_source">Source</string>
<string name="edit_info_info_date_added">Date added</string>
<string name="edit_info_source_unknown">Unknown</string>
<string name="edit_info_close">Close</string>
<string name="edit_info_discard_title">Discard changes?</string>
<string name="edit_info_discard_keep">Keep editing</string>
<string name="edit_info_discard_confirm">Discard</string>
```

- [ ] **Step 2: Add the Reader info-icon content description**

In `Android/FolinoReaderAndroid/src/main/res/values/strings.xml`, add:

```xml
<string name="reader_edit_info">Edit info</string>
```

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/res/values/strings.xml \
        Android/FolinoReaderAndroid/src/main/res/values/strings.xml
git commit -m "feat(android): edit-info string resources"
```

---

### Task 7: Build the `EditScoreInfoScreen` composable

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/scoreinfo/EditScoreInfoScreen.kt`

- [ ] **Step 1: Create the full-screen edit screen**

```kotlin
package com.keynumber.folino.ui.scoreinfo

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R
import com.keynumber.folino.library.EditScoreInfoWire
import java.text.DateFormat
import java.util.Date

/** Immutable snapshot of the six editable fields; used for change detection. */
private data class CreditFields(
    val title: String,
    val subtitle: String,
    val composer: String,
    val arranger: String,
    val lyricist: String,
    val copyright: String,
)

private fun EditScoreInfoWire.toFields() =
    CreditFields(title, subtitle, composer, arranger, lyricist, copyright)

/**
 * Material full-screen edit screen for a score's credit metadata. Loads the pre-filled snapshot via [load], persists
 * via [onSave]. Explicit Save (disabled on blank title); unsaved exit prompts a discard dialog. Mirrors iOS content;
 * Android placement (top-app-bar Save/Close, full-screen destination).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditScoreInfoScreen(
    load: () -> EditScoreInfoWire,
    onSave: (CreditFieldsOut) -> Unit,
    onClose: () -> Unit,
) {
    val initial = remember { load() }
    val baseline = remember { initial.toFields() }

    var title by remember { mutableStateOf(initial.title) }
    var subtitle by remember { mutableStateOf(initial.subtitle) }
    var composer by remember { mutableStateOf(initial.composer) }
    var arranger by remember { mutableStateOf(initial.arranger) }
    var lyricist by remember { mutableStateOf(initial.lyricist) }
    var copyright by remember { mutableStateOf(initial.copyright) }
    var showDiscard by remember { mutableStateOf(false) }

    val current = CreditFields(title, subtitle, composer, arranger, lyricist, copyright)
    val hasChanges = current != baseline
    val canSave = title.isNotBlank()

    fun attemptClose() {
        if (hasChanges) showDiscard = true else onClose()
    }

    BackHandler(enabled = true) { attemptClose() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.edit_info)) },
                navigationIcon = {
                    IconButton(onClick = { attemptClose() }) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.edit_info_close))
                    }
                },
                actions = {
                    TextButton(
                        enabled = canSave,
                        onClick = {
                            onSave(
                                CreditFieldsOut(
                                    title = title, subtitle = subtitle, composer = composer,
                                    arranger = arranger, lyricist = lyricist, copyright = copyright,
                                ),
                            )
                            onClose()
                        },
                    ) { Text(stringResource(R.string.edit_info_save)) }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            SectionHeader(stringResource(R.string.edit_info_section_credits))
            Field(stringResource(R.string.edit_info_field_title), title, singleLine = true) { title = it }
            Field(stringResource(R.string.edit_info_field_subtitle), subtitle, singleLine = true) { subtitle = it }
            Field(stringResource(R.string.edit_info_field_composer), composer, singleLine = true) { composer = it }
            Field(stringResource(R.string.edit_info_field_arranger), arranger, singleLine = true) { arranger = it }
            Field(stringResource(R.string.edit_info_field_lyricist), lyricist, singleLine = true) { lyricist = it }
            Field(stringResource(R.string.edit_info_field_copyright), copyright, singleLine = false) { copyright = it }

            Spacer(Modifier.height(16.dp))
            SectionHeader(stringResource(R.string.edit_info_section_info))
            ReadOnlyRow(
                stringResource(R.string.edit_info_info_source),
                initial.source.ifBlank { stringResource(R.string.edit_info_source_unknown) },
            )
            if (initial.addedAt > 0) {
                ReadOnlyRow(
                    stringResource(R.string.edit_info_info_date_added),
                    DateFormat.getDateInstance().format(Date((initial.addedAt * 1000).toLong())),
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showDiscard) {
        AlertDialog(
            onDismissRequest = { showDiscard = false },
            title = { Text(stringResource(R.string.edit_info_discard_title)) },
            confirmButton = {
                TextButton(onClick = { showDiscard = false; onClose() }) {
                    Text(stringResource(R.string.edit_info_discard_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { showDiscard = false }) {
                    Text(stringResource(R.string.edit_info_discard_keep))
                }
            },
        )
    }
}

/** Output payload handed to the wirelet `saveScoreInfo` call. */
data class CreditFieldsOut(
    val title: String,
    val subtitle: String,
    val composer: String,
    val arranger: String,
    val lyricist: String,
    val copyright: String,
)

@Composable
private fun SectionHeader(text: String) {
    Spacer(Modifier.height(8.dp))
    Text(text, style = androidx.compose.material3.MaterialTheme.typography.labelLarge)
    HorizontalDivider(Modifier.padding(vertical = 4.dp))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Field(label: String, value: String, singleLine: Boolean, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = singleLine,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    )
}

@Composable
private fun ReadOnlyRow(label: String, value: String) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Text(value, textAlign = TextAlign.End) },
    )
}
```

- [ ] **Step 2: Build the app to verify the composable compiles**

Run (cwd `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. (The screen is not yet wired into navigation — that's Task 8.)

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/scoreinfo/EditScoreInfoScreen.kt
git commit -m "feat(android): EditScoreInfoScreen full-screen editor"
```

---

### Task 8: Add the `editInfo/{id}` nav route

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (inside `LibraryNavGraph`'s `NavHost`, where `vm` is in scope)

- [ ] **Step 1: Add the destination**

In `MainActivity.kt`, inside the same `NavHost` that holds the `"reader/{id}/{title}"` route (where `vm: LibraryAndroidStoreViewModel` and `nav` are in scope), add a new `composable`:

```kotlin
composable(
    "editInfo/{id}",
    arguments = listOf(navArgument("id") { type = NavType.StringType }),
) { entry ->
    val id = entry.arguments?.getString("id") ?: ""
    com.keynumber.folino.ui.scoreinfo.EditScoreInfoScreen(
        load = { vm.scoreInfoForEditing(id) },
        onSave = { f ->
            vm.saveScoreInfo(id, f.title, f.subtitle, f.composer, f.arranger, f.lyricist, f.copyright)
        },
        onClose = { nav.popBackStackIfResumed() },
    )
}
```

> Use the same back-pop helper the Reader route uses (`nav.popBackStackIfResumed()` per the Reader composable). If that helper isn't in scope here, use `nav.popBackStack()`.

- [ ] **Step 2: Build to verify wiring compiles**

Run (cwd `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): editInfo nav route"
```

---

### Task 9: Library overflow → "Edit info"

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt` (menu 396-431, `ScoreRow` params 361-372, call site 264-295)
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (pass an `onEditInfo` into the scaffold/screen)

- [ ] **Step 1: Add the menu item**

In `ScoreListScaffold.kt`, inside the `DropdownMenu` (lines 396-431), add after the `edit_tags` item:

```kotlin
DropdownMenuItem(
    text = { Text(stringResource(R.string.edit_info)) },
    onClick = {
        menu = false
        onEditInfo()
    },
)
```

- [ ] **Step 2: Thread the callback through `ScoreRow`**

In `ScoreListScaffold.kt`, add `onEditInfo: () -> Unit,` to the `ScoreRow` parameter list (after `onExport` at line 371), and at the call site (lines 264-295) add:

```kotlin
            onEditInfo = { onEditInfoForScore(row.id) },
```

Add a top-level parameter `onEditInfoForScore: (String) -> Unit` to the scaffold composable (the same place `viewModel`, `onOpenScore` are declared) and forward it. (Mirror how `onOpenScore` is plumbed.)

- [ ] **Step 3: Provide the callback from MainActivity**

Where `LibraryNavGraph` builds the list screen / scaffold (the call that passes `onOpenScore = openReader`), add:

```kotlin
            onEditInfoForScore = { id -> nav.navigate("editInfo/$id") },
```

- [ ] **Step 4: Build to verify**

Run (cwd `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt \
        Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): Library overflow Edit info entry"
```

---

### Task 10: Reader top bar → info icon

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (signature 72-90, actions 175-189)
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (reader route, lines 412-433)

- [ ] **Step 1: Add the `onEditInfo` parameter to `ReaderScreen`**

In `ReaderScreen.kt`, add to the composable signature (after `onBack`):

```kotlin
    onEditInfo: () -> Unit = {},
```

- [ ] **Step 2: Add the info IconButton to the top bar**

In `ReaderScreen.kt` `actions` block (before the display-settings `IconButton`, ~line 182), add:

```kotlin
                IconButton(onClick = onEditInfo) {
                    Icon(
                        Icons.Outlined.Info,
                        contentDescription = stringResource(R.string.reader_edit_info),
                    )
                }
```

Add the import `import androidx.compose.material.icons.outlined.Info`.

- [ ] **Step 3: Wire the Reader route to navigate**

In `MainActivity.kt`, in the `"reader/{id}/{title}"` composable, add to the `ReaderScreen(...)` call (alongside `onBack = ...`):

```kotlin
        onEditInfo = { nav.navigate("editInfo/$id") },
```

`id` is already in scope in that route (`val id = entry.arguments?.getString("id") ?: ""`).

- [ ] **Step 4: Build to verify**

Run (cwd `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt \
        Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): Reader top bar Edit info entry"
```

---

### Task 11: File-metaTag pre-fill + source label (graceful degradation)

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreMetadataReading.swift` (add `ScoreSourceKind.displayLabel`)
- Create: `Packages/Domain/Tests/DomainTests/ScoreSourceKindLabelTests.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` (`scoreInfoForEditing` reads the file)

- [ ] **Step 1: Write the failing label test**

Create `Packages/Domain/Tests/DomainTests/ScoreSourceKindLabelTests.swift`:

```swift
import Testing
@testable import Domain

@Suite struct ScoreSourceKindLabelTests {
    @Test func labels() {
        #expect(ScoreSourceKind.museScore(majorVersion: 4).displayLabel == "MuseScore 4")
        #expect(ScoreSourceKind.musicXML.displayLabel == "MusicXML")
        #expect(ScoreSourceKind.midi.displayLabel == "MIDI")
        #expect(ScoreSourceKind.pdf.displayLabel == "PDF")
        #expect(ScoreSourceKind.unknown.displayLabel == "")   // caller substitutes a localized "Unknown"
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/ScoreSourceKindLabelTests`
Expected: FAIL — `displayLabel` undefined.

- [ ] **Step 3: Add `displayLabel`**

In `Packages/Domain/Sources/Domain/Protocols/ScoreMetadataReading.swift`, add:

```swift
public extension ScoreSourceKind {
    /// Brand/format label for the read-only Info row. Brand literals are intentionally NOT localized (iOS parity).
    /// `.unknown` returns "" so the UI can substitute its own localized "Unknown".
    var displayLabel: String {
        switch self {
        case let .museScore(majorVersion): "MuseScore \(majorVersion)"
        case .musicXML: "MusicXML"
        case .midi: "MIDI"
        case .pdf: "PDF"
        case .unknown: ""
        }
    }
}
```

- [ ] **Step 4: Run the label test to verify it passes**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/ScoreSourceKindLabelTests`
Expected: PASS.

- [ ] **Step 5: Read file metaTags + source in `scoreInfoForEditing`**

In `LibraryAndroidStore.swift`, replace the `scoreInfoForEditing` body so it parses the score and supplies `fileMetadata` + the source label. Reuse the same `MSCZReader.parse` the export path uses; read the same metaTag keys iOS's `LiveScoreMetadataReader` reads (`composer`/`arranger`/`lyricist`/`copyright`). On any parse failure, fall back to `nil`/`""` (the score still edits — graceful degradation):

```swift
@WireletExpose
public func scoreInfoForEditing(_ id: String) -> EditScoreInfoWire {
    guard let record = store.loadAll().first(where: { $0.id == id }) else {
        return EditScoreInfoWire(title: "", subtitle: "", composer: "", arranger: "",
                                 lyricist: "", copyright: "", source: "", addedAt: 0)
    }
    let path = "\(store.scoresDirectoryPath())/\(record.localFileName)"
    let url = URL(fileURLWithPath: path)
    let score = try? MSCZReader.parse(contentsOf: url)

    func metaTag(_ key: String) -> String? {
        guard let v = score?.metaTags[key], !v.isEmpty else { return nil }
        return v
    }
    let fileMetadata: ScoreFileMetadata? = score.map { s in
        ScoreFileMetadata(
            source: ScoreSourceKind(source: s.source),  // map ssm source → Domain kind (see note)
            composer: metaTag("composer"),
            arranger: metaTag("arranger"),
            lyricist: metaTag("lyricist"),
            copyright: metaTag("copyright"),
        )
    }
    let prefill = EditableScoreInfo.prefilled(
        title: record.title, subtitle: record.subtitle, composer: record.composer,
        arranger: record.arranger, lyricist: record.lyricist, copyright: record.copyright,
        fileMetadata: fileMetadata,
    )
    let addedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)?
        .timeIntervalSince1970 ?? 0
    return EditScoreInfoWire(
        title: prefill.title, subtitle: prefill.subtitle, composer: prefill.composer,
        arranger: prefill.arranger, lyricist: prefill.lyricist, copyright: prefill.copyright,
        source: fileMetadata?.source.displayLabel ?? "", addedAt: addedAt,
    )
}
```

> **Mapping note:** `ScoreSourceKind(source:)` is the ssm-`source`→Domain-kind mapping. iOS already performs this mapping in `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileMetadata+Score.swift`. To stay non-divergent, lift that exact mapping into a small Domain (or shared) initializer `ScoreSourceKind(source:)` and call it from both `ScoreFileMetadata+Score.swift` (iOS) and here. If the ssm `source` type isn't linkable from `FolinoLibraryJNI`, derive the kind from the file extension / `MSCZReader` result available here, matching the same cases. Confirm buildability in Step 6 before finalizing.

- [ ] **Step 6: Rebuild the Android library and confirm buildability**

Run: `Scripts/android-build-library-libs.sh`
Expected: builds. If `score.metaTags` / `s.source` are not available on the Android `MSCZReader` result, keep `fileMetadata = nil` and `source = ""` (the Task 5 behavior) — the feature still works; only the convenience pre-fill and source label are skipped. Document whichever path was taken in the commit message.

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreMetadataReading.swift \
        Packages/Domain/Tests/DomainTests/ScoreSourceKindLabelTests.swift \
        Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(android): edit-info file-metaTag prefill + source label"
```

---

### Task 12: Device verification (Pixel)

**Files:** none (verification only)

- [ ] **Step 1: Build the full Android library + app**

Run: `Scripts/android-build-library-libs.sh`
Then (cwd `Android/`): `./gradlew :app:installDebug`
Expected: APK installs on the connected Pixel.

- [ ] **Step 2: Launch**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: app launches without an `UnsatisfiedLinkError` (confirms the new JNI symbols linked).

- [ ] **Step 3: Smoke the Library entry**

Manually: open a score's `⋮` overflow → **Edit info** → full-screen editor appears with pre-filled fields → edit Title/Composer → **Save** → list row reflects the new title.

- [ ] **Step 4: Smoke the Reader entry**

Manually: open a score in the Reader → tap the **info** icon in the top bar → editor appears → change a field → **Save** → returns to Reader; the top-bar title reflects a title change.

- [ ] **Step 5: Smoke the guards**

Manually verify: clearing Title disables **Save**; editing then pressing **✕** or system back shows the **Discard changes?** dialog (Keep editing / Discard); an unchanged screen closes with no dialog.

- [ ] **Step 6: Verify Room migration on upgrade**

Manually: install the new build over a pre-existing v1 install (do **not** uninstall first); confirm the app launches and existing scores load (migration `1→2` applied, no crash).

- [ ] **Step 7: Commit any fixes found during smoke**

Commit message: `fix(android): edit-info smoke fixes` (only if changes were needed).

---

## Self-Review

**Spec coverage:**
- Material full-screen recognition model → Task 7 (`EditScoreInfoScreen`), Task 8 (own nav destination).
- Six editable fields + read-only Info (Source, Date added) → Task 7.
- Library overflow entry (single only) → Task 9. Reader top-bar info icon → Task 10.
- Explicit Save (disabled on blank title) + discard confirmation + system back → Task 7.
- Shared value type + prefill + normalization in Domain; iOS adopts → Tasks 1–2.
- `saveScoreInfo` / `scoreInfoForEditing` wirelet bridges → Tasks 4–5. Room migration for arranger/lyricist/copyright → Task 3.
- Reader save path via callback (module stays decoupled) → Tasks 8, 10.
- File-metaTag prefill with graceful degradation → Task 11. Date added via file creation date → Task 5.
- Tests (Domain unit, device smoke, migration) → Tasks 1, 11, 12.

**Open spec items resolved:**
1. Compose home = `Android/app/.../ui/scoreinfo/EditScoreInfoScreen.kt`, reachable as nav route `editInfo/{id}` from both surfaces (Task 8).
2. `ScoreInfoEditing` protocol stays in `ScoreUI`; only the value type + pure functions moved to Domain (Task 1).
3. `LiveScoreMetadataReader` Android buildability is verified in Task 11 Step 6, with a documented fallback.

**Deliberate v1 notes:** "Date added" uses the score file's filesystem creation date rather than a new persisted `addedAt` column, avoiding an import-path + schema change. The source label depends on Task 11's parse path; until then it shows the localized "Unknown".

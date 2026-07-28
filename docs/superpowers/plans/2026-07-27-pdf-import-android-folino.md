# PDF Import on Android (Folino) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship PDF import on Folino for Android at iOS parity — a PDF becomes a library item, reads as its original pages in the Reader, takes freehand annotation, and gains playback with an on-PDF cursor once a background OMR parse succeeds.

**Architecture:** Two layers. Display is `android.graphics.pdf.PdfRenderer` bitmaps in two new Compose surfaces (vertical-continuous and paged) that slot into the existing Reader shell. Playback comes from swift-sheet-music's PDF geometry bridge: the parsed score's handle enters the existing `_scoreHandle` path so transport, mixer, repeat and PiP work unchanged, and only the cursor lookup swaps to the PDF geometry entry points. All rules (accepted formats, title derivation, capabilities, annotation anchoring) stay in shared Swift and cross by JNI.

**Tech Stack:** Kotlin + Jetpack Compose, Room, androidx.ink, swift-wirelet JNI bridges (`FolinoLibraryJNI` / `FolinoReaderJNI`), swift-java (ssm), Swift Testing.

## Global Constraints

- **Prerequisite:** the swift-sheet-music plan `docs/superpowers/plans/2026-07-27-pdf-geometry-android.md` must be complete, merged to ssm `main`, and published to mavenLocal. Folino resolves ssm from mavenLocal with no `-PssmVersion` override.
- Spec: `docs/superpowers/specs/2026-07-27-pdf-import-android-design.md`. Read it before Task 1.
- **No new third-party dependency.** `PdfRenderer` is Android framework. Adding a dependency needs explicit user approval.
- **No Room schema change and no `fallbackToDestructiveMigration`.** The database ships to real users; `localFileName`'s extension already carries the format.
- Parity rule (CLAUDE.md): logic and behavior match iOS and are *shared*, never re-implemented in Kotlin; UI placement follows Android idioms.
- The user-facing brand is lowercase `folino`. `PDF` is a literal, deliberately unlocalized.
- New Swift tests use Swift Testing. Swift package tests run through `xcodebuild test` on `platform=iOS Simulator,name=iPhone 17 Pro Max` — `swift test` does not work in this repo.
- **Android build order is mandatory: Gradle wirelet codegen → rebuild `.so` → `assembleDebug`.** Reversed, the `.so`'s `JNI_OnLoad` misses the new symbols and the app crashes at launch.
- `java-generated/` and `jniLibs/` are gitignored, so they never travel with a merge. After merging, copy them into the primary checkout or the primary build breaks.
- Android verification runs on the physical Pixel 8a by default. Do not start an emulator unless asked. Every Android change is verified through `installDebug` + launch.
- Work happens in `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android` on branch `worktree-pdf-import-android`. Use `git -C <that path>` for every git call.
- Comment paragraphs reflow at 120 columns. Access modifiers stay minimal — no `public` on anything that does not cross a module boundary.

---

## File Structure

**Create**

| File | Responsibility |
| --- | --- |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/PageAnchoringCore.swift` | Platform-neutral page-anchor geometry lifted out of the iOS-only `PDFAnnotationAnchoring`. |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/PdfAnnotationBridge.swift` | JNI capture / display-transform entry points for page anchors. |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderCapabilitiesWire.swift` | Wire projection of `Domain.ReaderCapabilities` + the `canPlayNow` rule. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfPageSource.kt` | Serialized `PdfRenderer` access + windowed bitmap cache. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfVerticalScore.kt` | Vertical-continuous PDF surface. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PagedPdfScore.kt` | Paged PDF surface. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfPlaybackState.kt` | The four-state OMR readiness enum + its payload. |
| `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/pdf/PdfPageWindowTest.kt` | Unit test for the cache window arithmetic. |

**Modify**

| File | Change |
| --- | --- |
| `Packages/Domain/Sources/Domain/Models/ReaderCapabilities.swift` | Add the shared `canPlayNow` rule. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` | PDF branch in `importScore`; `<id>.pdf` naming. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift` | `isPdf` field. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire+Sorting.swift` or a new small file | Accepted-extension exposure for Kotlin. |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift` | `DrawingAnchorWire` gains `anchorKind` + `pageIndex`. |
| `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift` | Becomes a PencilKit adapter over the lifted core. |
| `Android/app/src/main/AndroidManifest.xml` | `application/pdf` on the three intent-filters. |
| `Android/app/src/main/kotlin/com/keynumber/folino/share/ShareImport.kt` | Drop the duplicated extension set. |
| `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt` | PDF label in the row. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderState.kt` | `ReadyPdf` case. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt` | File resolution by `localFileName`; PDF load + background OMR parse. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` | Branch to the PDF surfaces; capability gating. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt` | Hide unavailable controls; PDF explanation row. |

---

### Task 1: One source of truth for accepted formats

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/share/ShareImport.kt`
- Modify: `Android/app/src/main/AndroidManifest.xml`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/AcceptedFormatsTests.swift` (create)

**Interfaces:**
- Consumes: `Domain.ShareImportPolicy.acceptedExtensions` / `.isAccepted(filename:)` (already contains `"pdf"`).
- Produces: `LibraryAndroidStore.isAcceptedScoreFilename(_ name: String) -> Bool`, exposed with `@WireletExpose`, callable from Kotlin as `viewModel.isAcceptedScoreFilename(name)`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Library/Tests/FolinoLibraryJNITests/AcceptedFormatsTests.swift`. Model it on the existing suites in that directory (read `LibraryAndroidStoreTests.swift` first for how a store is constructed with its fakes).

```swift
import Domain
import Testing
@testable import FolinoLibraryJNI

@Suite struct AcceptedFormatsTests {
    @Test func acceptsEveryDomainExtension() {
        let store = makeStore()
        for ext in ShareImportPolicy.acceptedExtensions {
            #expect(store.isAcceptedScoreFilename("score.\(ext)"))
        }
    }

    @Test func acceptsPDF() {
        #expect(makeStore().isAcceptedScoreFilename("Prelude.pdf"))
    }

    @Test func isCaseInsensitive() {
        #expect(makeStore().isAcceptedScoreFilename("Prelude.PDF"))
    }

    @Test func rejectsUnrelatedFiles() {
        let store = makeStore()
        #expect(!store.isAcceptedScoreFilename("photo.jpg"))
        #expect(!store.isAcceptedScoreFilename("noextension"))
    }
}
```

Add whatever `makeStore()` helper the neighbouring tests already use rather than inventing one.

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Features/Library
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Library-Package/AcceptedFormatsTests
```

Expected: FAIL — `isAcceptedScoreFilename` does not exist. (If the scheme name is wrong, list schemes with `xcodebuild -list`; single-product packages use the product name, multi-product use `<PackageName>-Package`.)

- [ ] **Step 3: Expose the rule**

In `LibraryAndroidStore.swift`, next to `importScore`:

```swift
/// Whether `name`'s extension is an importable score format. The one gate for the Library picker and
/// the share/open-with transport — Kotlin previously kept a duplicate of `ShareImportPolicy`'s set and
/// had to be hand-synced; this crosses the real Domain rule instead.
@WireletExpose
public func isAcceptedScoreFilename(_ name: String) -> Bool {
    ShareImportPolicy.isAccepted(filename: name)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS, 4 tests.

- [ ] **Step 5: Delete the Kotlin duplicate**

In `ShareImport.kt`, remove the `ACCEPTED` literal and the `isAcceptedScoreFilename` / `isAccepted` functions, and thread the store-backed check in instead: `stageSharedUris` takes an `isAccepted: (String) -> Boolean` parameter, and both call sites (`LibraryScreen.kt`'s picker callback and the share transport) pass `viewModel::isAcceptedScoreFilename`. Compile-check by grepping for stragglers:

```bash
rg -n "isAcceptedScoreFilename|ACCEPTED" Android/app/src/main/kotlin
```

Expected: only the new parameter-passing call sites remain.

- [ ] **Step 6: Accept PDFs from other apps**

In `Android/app/src/main/AndroidManifest.xml`, add `<data android:mimeType="application/pdf" />` to each of the three intent-filters that currently list `application/octet-stream` (`SEND`, `SEND_MULTIPLE`, `VIEW`).

- [ ] **Step 7: Build and commit**

```bash
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
Scripts/android-build-library-libs.sh
cd Android && ./gradlew :app:assembleDebug
```

Expected: BUILD SUCCESSFUL. Then commit the Swift, Kotlin and manifest changes together.

---

### Task 2: Import a PDF

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift:97-131`
- Modify: `Packages/Features/Library/Package.swift` (test resources, if the JNI test target has none)
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/PDFImportTests.swift` (create)
- Copy: `Packages/Infrastructure/Tests/InfrastructureTests/Resources/sample.pdf` → `Packages/Features/Library/Tests/FolinoLibraryJNITests/Resources/sample.pdf`

**Interfaces:**
- Consumes: `ScoreFormat.detect(filename:)`, `ScoreFormat.canonicalExtension`, `ScorePresentation.displayFields(sourceFilename:score:)` (all Domain, existing); `PDFImporter.summaryUsingSwiftReader(pdfData:) -> PDFDocumentSummary?` (ssm, from the ssm plan Task 1).
- Produces: `importScore` handling `.pdf`, storing `<id>.pdf`, titling from `/Title` with a filename fallback.

`sample.pdf` is a 2-page PDF whose `/Title` is `"Sample Title"` (generated by `Scripts/make-sample-pdf.swift`), which is exactly what this test needs.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
import Testing
@testable import FolinoLibraryJNI

@Suite struct PDFImportTests {
    private func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
    }

    @Test func importsAPDFAsALiveRecord() throws {
        let store = makeStore()
        _ = store.importScore(try fixtureURL().path)
        let records = store.loadAllRecordsForTesting().filter { $0.deletedAt == 0 }
        #expect(records.count == 1)
    }

    /// iOS `LiveScoreFileImporter` prefers the PDF's `/Title` over the filename.
    @Test func titleComesFromTheDocumentTitle() throws {
        let store = makeStore()
        _ = store.importScore(try fixtureURL().path)
        let record = try #require(store.loadAllRecordsForTesting().first)
        #expect(record.title == "Sample Title")
    }

    /// Same "<id>.<canonicalExtension>" convention iOS uses — the extension is what tells the Reader
    /// which loader to use, so it must be `.pdf`, not `.mscz`.
    @Test func storesWithAPdfExtension() throws {
        let store = makeStore()
        _ = store.importScore(try fixtureURL().path)
        let record = try #require(store.loadAllRecordsForTesting().first)
        #expect(record.localFileName.hasSuffix(".pdf"))
    }

    @Test func analyticsReportsThePdfFormat() throws {
        let store = makeStore()
        let event = store.importScore(try fixtureURL().path)
        #expect(AnalyticsBridge.decodeNameForTesting(event) == "score_imported")
    }

    @Test func unreadableBytesFailCleanly() throws {
        let store = makeStore()
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: junk)
        let event = store.importScore(junk.path)
        #expect(AnalyticsBridge.decodeNameForTesting(event) == "score_import_failed")
        #expect(store.loadAllRecordsForTesting().isEmpty)
    }

    /// The existing MuseScore path must be untouched.
    @Test func msczStillImports() throws {
        let store = makeStore()
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))
        _ = store.importScore(url.path)
        let record = try #require(store.loadAllRecordsForTesting().first)
        #expect(record.localFileName.hasSuffix(".mscz"))
    }
}
```

`makeStore()`, `loadAllRecordsForTesting()` and `AnalyticsBridge.decodeNameForTesting` stand in for whatever the existing suites in `Tests/FolinoLibraryJNITests/` already provide — read `LibraryAndroidStoreTests.swift` and `ExportScoreTests.swift` and use their real helpers and their real fake store. If a `.mscz` fixture is not already in that target, drop the last test rather than adding a new binary fixture.

Register the resource in `Packages/Features/Library/Package.swift` on the `FolinoLibraryJNITests` target if it has no `resources:` entry yet:

```swift
resources: [.process("Resources")],
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Features/Library
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Library-Package/PDFImportTests
```

Expected: FAIL — the PDF import produces no record (the current code runs `MSCZReader.parse`, which rejects PDF bytes).

- [ ] **Step 3: Branch `importScore` on format**

Replace the body of `importScore` so the parse and the display fields are chosen by format, keeping every other step (id, hash, copy, upsert, reload, analytics) shared:

```swift
@WireletExpose
public func importScore(_ path: String) -> AnalyticsEventWire {
    let url = URL(fileURLWithPath: path)
    let pickedFormat = ScoreFormat.detect(filename: url.lastPathComponent)
    let fields: ScorePresentation.DisplayFields
    let format: ScoreFormat
    if pickedFormat == .pdf {
        // A PDF is imported as a fixed-layout document: no notation is decoded here. The playable score
        // is produced later, in the Reader, by the background OMR parse. Title rule matches iOS
        // (`LiveScoreFileGateway.pdfSummary`): the document `/Title` when present, else the filename.
        guard let data = try? Data(contentsOf: url),
              let summary = PDFImporter.summaryUsingSwiftReader(pdfData: data)
        else {
            return AnalyticsBridge.encode(.scoreImportFailed(format: "pdf", reason: "parse_failed"))
        }
        fields = ScorePresentation.displayFields(
            sourceFilename: url.lastPathComponent, pdfTitle: summary.title,
        )
        format = .pdf
    } else {
        guard let score = try? MSCZReader.parse(contentsOf: url) else {
            return AnalyticsBridge.encode(
                .scoreImportFailed(format: pickedFormat?.analyticsValue ?? "unknown", reason: "parse_failed"),
            )
        }
        fields = ScorePresentation.displayFields(sourceFilename: url.lastPathComponent, score: score)
        format = .mscz
    }
    let id = UUID().uuidString
    let localFileName = "\(id).\(format.canonicalExtension)"
    ...  // hash / copyImportedFile / upsert / reload / analytics exactly as today
}
```

Check `ScorePresentation` for an existing PDF-titling entry point before adding `displayFields(sourceFilename:pdfTitle:)`:

```bash
rg -n "func displayFields" -A 12 Packages/Domain/Sources/Domain
```

iOS derives the PDF title in `LiveScoreFileImporter.swift:102-106` (`plan.format == .pdf ? (plan.summary.title ?? filenameTitle) : filenameTitle`). If that rule is not yet a shared function, **move it into `ScorePresentation` and have iOS call it too** — a second copy of the rule in the Android path is exactly what the parity rule forbids. That iOS edit belongs in this task.

Add `import SheetMusicPDF` to the file. Confirm `FolinoLibraryJNI`'s target in `Packages/Features/Library/Package.swift` already depends on it; if not, add the dependency (it is an existing package dependency of the repo, not a new third-party one).

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Run the whole Library package and the iOS app build**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Features/Library
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: both succeed. The app build proves the shared-title refactor did not break iOS.

- [ ] **Step 6: Commit**

---

### Task 3: PDF marker in the library row

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` (row construction)
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt:419-440`
- Test: extend `Packages/Features/Library/Tests/FolinoLibraryJNITests/PDFImportTests.swift`

**Interfaces:**
- Consumes: `ScoreFormat.detect(filename:)`.
- Produces: `ScoreRowWire.isPdf: Bool` — Kotlin sees it as `row.isPdf`.

- [ ] **Step 1: Write the failing test**

Append to `PDFImportTests`:

```swift
@Test func rowsFlagPdfItems() throws {
    let store = makeStore()
    _ = store.importScore(try fixtureURL().path)
    let row = try #require(store.scores.first)
    #expect(row.isPdf)
}
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — `isPdf` is not a member of `ScoreRowWire`.

- [ ] **Step 3: Add the field**

In `ScoreRowWire.swift` add `public var isPdf: Bool` with a defaulted `false` in the memberwise `init`, mirroring how `isFavorite` is declared. Where rows are built from records in `LibraryAndroidStore`, set it with `ScoreFormat.detect(filename: record.localFileName) == .pdf` — the same derivation `ScoreRow.swift:45-47` uses on iOS.

- [ ] **Step 4: Run the test to verify it passes**

- [ ] **Step 5: Show it in the row**

In `ScoreListScaffold.kt`'s private `ScoreRow`, render a small `"PDF"` label when `row.isPdf`. Place it in the row's supporting/metadata line as an `AssistChip`-style label using `MaterialTheme.typography.labelSmall` and `MaterialTheme.colorScheme.onSurfaceVariant` — Android convention, not a copy of the iOS capsule. The text is the literal `"PDF"`, deliberately not localized (same reasoning as `PDFBadge` on iOS).

- [ ] **Step 6: Rebuild the library `.so`, assemble, commit**

```bash
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
Scripts/android-build-library-libs.sh
cd Android && ./gradlew :app:assembleDebug
```

Expected: BUILD SUCCESSFUL. A `WireFormatException` or `UnsatisfiedLinkError` at this point means the `.so` was built before codegen — rerun in the documented order.

---

### Task 4: Reader opens the right file

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt:192-194` and its `load(scoreId:)`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderState.kt`

**Interfaces:**
- Consumes: `RoomLibraryStore(context).loadAll()` → `ScoreRecordWire.localFileName` (Room column `local_file_name`).
- Produces: `ReaderState.ReadyPdf(pageCount: Int, pageWidthsPt: List<Double>, pageHeightsPt: List<Double>)`; `ReaderViewModel.load` dispatching on the resolved file's extension.

- [ ] **Step 1: Add the state case**

```kotlin
sealed interface ReaderState {
    data object Loading : ReaderState
    data class Error(val message: String) : ReaderState
    data class Ready(val program: DrawProgram) : ReaderState

    /**
     * A fixed-layout PDF. Carries only what the surfaces need to lay pages out before any bitmap is
     * rendered; the pixels come from [PdfPageSource]. Page sizes are PDF points, as `PdfRenderer`
     * reports them.
     */
    data class ReadyPdf(
        val pageCount: Int,
        val pageWidthsPt: List<Double>,
        val pageHeightsPt: List<Double>,
    ) : ReaderState
}
```

- [ ] **Step 2: Resolve the file by record, not by convention**

Replace `scoreFile(scoreId)`'s hardcoded `"$scoreId.mscz"` with a lookup of the record's `localFileName` in `filesDir/Scores/`, falling back to `"$scoreId.mscz"` only when no record is found (so an unknown id still fails with the existing "Score file not found" error rather than crashing).

- [ ] **Step 3: Branch `load`**

In `load(scoreId:)`, after reading the bytes, branch on the resolved file's extension:

- `.pdf` → open it with `PdfRenderer` (Task 6's `PdfPageSource`) and publish `ReaderState.ReadyPdf`. Do **not** install SMuFL metrics or call `ScoreHandle.load`, and leave `_scoreHandle` null so the layout recompute loop stays idle.
- anything else → today's path, unchanged.

Until Task 6 lands, publish `ReadyPdf` with page count and sizes read from a bare `PdfRenderer` opened inline; Task 6 replaces that with the cache-backed source.

- [ ] **Step 4: Verify the reader still opens a `.mscz`**

```bash
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
Scripts/android-build-reader-libs.sh
cd Android && ./gradlew :app:installDebug
adb shell am start -n com.keynumber.folino/.MainActivity
```

Open an existing score. Expected: unchanged behavior. A PDF item will not render yet (Task 7) — that is the expected intermediate state; note it when reporting.

- [ ] **Step 5: Commit**

---

### Task 5: Capabilities cross the boundary

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderCapabilities.swift`
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderCapabilitiesWire.swift`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`, `DisplayInspectorSheet.kt`
- Test: `Packages/Domain/Tests/DomainTests/ReaderCapabilitiesTests.swift` (extend)

**Interfaces:**
- Consumes: `ReaderCapabilities.resolve(format:)`, `ReaderLayoutMode`.
- Produces:
  - Domain: `static func canPlayNow(capabilities: ReaderCapabilities, isPDFPlaybackReady: Bool) -> Bool`
  - JNI: `nativeReaderCapabilities(isPdf: Bool) -> Data` → `ReaderCapabilitiesWire { canPlay, canChangeLayout, canTranspose, canEditStaves: Bool, layoutModes: [String] }`
  - JNI: `nativeCanPlayNow(canPlay: Bool, isPdfPlaybackReady: Bool) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
@Test func pdfBecomesPlayableOnlyWhenTheParseSucceeds() {
    let pdf = ReaderCapabilities.forPDF
    #expect(!ReaderCapabilities.canPlayNow(capabilities: pdf, isPDFPlaybackReady: false))
    #expect(ReaderCapabilities.canPlayNow(capabilities: pdf, isPDFPlaybackReady: true))
}

@Test func scoresArePlayableRegardlessOfPdfReadiness() {
    let score = ReaderCapabilities.forScore
    #expect(ReaderCapabilities.canPlayNow(capabilities: score, isPDFPlaybackReady: false))
}

@Test func pdfOffersPageAndVerticalOnly() {
    #expect(ReaderCapabilities.forPDF.availableLayoutModes == [.page, .vertical])
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Domain
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Domain/ReaderCapabilitiesTests
```

Expected: FAIL — `canPlayNow` does not exist.

- [ ] **Step 3: Add the rule and the wire**

In `ReaderCapabilities.swift`:

```swift
/// Whether a reader session may play right now. A score is playable from its format alone; a PDF only
/// after the background OMR parse succeeds. iOS reads this through `ReaderViewModel.canPlayNow`; Android
/// through `nativeCanPlayNow`. One rule, both platforms.
public static func canPlayNow(capabilities: ReaderCapabilities, isPDFPlaybackReady: Bool) -> Bool {
    capabilities.canPlay || isPDFPlaybackReady
}
```

Then point iOS's existing `ReaderViewModel.canPlayNow` (`ReaderViewModel+PDFPlayback.swift:52-54`) at it instead of repeating the expression.

Create `ReaderCapabilitiesWire.swift` in `FolinoReaderJNI` following the `@WireFormat` style of `AnnotationWire.swift`, plus the two swift-java entry points described under **Produces**. Encode layout modes as their `rawValue` strings so Kotlin's existing `ReaderLayoutMode.fromPref` maps them with no new parsing.

- [ ] **Step 4: Run the test to verify it passes**

- [ ] **Step 5: Gate the Android UI**

In `ReaderScreen.kt`, fetch the capabilities once per opened item and use them to decide which layout modes the mode picker offers and whether transport controls are enabled. In `DisplayInspectorSheet.kt`, hide the transpose stepper, staff-size control, voice and clef rows when `!canTranspose` / `!canEditStaves`, and show one explanatory line in their place. Add the string to `Android/app/src/main/res/values/strings.xml` (and the `values-ja` counterpart), translating the iOS key `reader.pdf.settingsNote` from `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` — reuse its en and ja values rather than writing new copy.

Kotlin must not re-derive any of this from the format — it renders what the wire says.

- [ ] **Step 6: Build, install, commit**

---

### Task 6: PDF page source

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfPageSource.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/pdf/PdfPageWindowTest.kt`

**Interfaces:**
- Produces:
  - `internal object PdfPageWindow { fun range(current: Int, pageCount: Int, radius: Int): IntRange }`
  - `internal class PdfPageSource(file: File) : AutoCloseable` with `val pageCount: Int`, `fun pageSizePt(index: Int): Size`, `suspend fun bitmap(index: Int, widthPx: Int): Bitmap?`, `fun setWindow(current: Int, radius: Int)`

`PdfRenderer` opens one page at a time, so every call goes through a single-threaded dispatcher. The window arithmetic is separated out because it is the only part worth unit-testing off-device.

- [ ] **Step 1: Write the failing test**

```kotlin
package com.keynumber.folino.reader.pdf

import org.junit.Assert.assertEquals
import org.junit.Test

class PdfPageWindowTest {
    @Test fun windowIsCenteredInTheMiddleOfADocument() {
        assertEquals(3..7, PdfPageWindow.range(current = 5, pageCount = 20, radius = 2))
    }

    @Test fun windowClampsAtTheStart() {
        assertEquals(0..2, PdfPageWindow.range(current = 0, pageCount = 20, radius = 2))
    }

    @Test fun windowClampsAtTheEnd() {
        assertEquals(17..19, PdfPageWindow.range(current = 19, pageCount = 20, radius = 2))
    }

    @Test fun windowNeverExceedsAShortDocument() {
        assertEquals(0..1, PdfPageWindow.range(current = 1, pageCount = 2, radius = 5))
    }

    @Test fun emptyDocumentYieldsAnEmptyRange() {
        assertEquals(IntRange.EMPTY, PdfPageWindow.range(current = 0, pageCount = 0, radius = 2))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Android
./gradlew :FolinoReaderAndroid:testDebugUnitTest --tests '*PdfPageWindowTest'
```

Expected: FAIL — unresolved reference `PdfPageWindow`.

- [ ] **Step 3: Implement the source**

```kotlin
package com.keynumber.folino.reader.pdf

internal object PdfPageWindow {
    /** Pages to keep rasterized around [current], clamped to the document. Empty when there are no pages. */
    fun range(current: Int, pageCount: Int, radius: Int): IntRange {
        if (pageCount <= 0) return IntRange.EMPTY
        val lo = (current - radius).coerceIn(0, pageCount - 1)
        val hi = (current + radius).coerceIn(0, pageCount - 1)
        return lo..hi
    }
}
```

`PdfPageSource` wraps `ParcelFileDescriptor.open(file, MODE_READ_ONLY)` and a `PdfRenderer`. Requirements:

- All `PdfRenderer` / `PdfRenderer.Page` access happens on one dedicated single-thread dispatcher; a page is opened, rendered and closed inside one block. Never hold two pages open.
- `bitmap(index, widthPx)` renders at `widthPx` and the page's aspect ratio with `Bitmap.Config.ARGB_8888` and `RENDER_MODE_FOR_DISPLAY`, returning a cached bitmap when one exists at that width.
- `setWindow(current, radius)` recycles and drops every cached page outside `PdfPageWindow.range`, and cancels in-flight renders for dropped pages.
- `close()` closes the renderer and the descriptor and recycles the cache; it is safe to call twice.
- `pageSizePt(index)` returns `PdfRenderer.Page.getWidth()/getHeight()` (PDF points), which the geometry projection in Task 13 compares against ssm's mediaBox.

- [ ] **Step 4: Run the test to verify it passes**

Expected: PASS, 5 tests.

- [ ] **Step 5: Point `ReaderViewModel` at it**

Replace Task 4 Step 3's inline `PdfRenderer` with `PdfPageSource`, holding it on the view model and closing it when the reader is retargeted or cleared.

- [ ] **Step 6: Commit**

---

### Task 7: Vertical PDF surface

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfVerticalScore.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:892-915`

**Interfaces:**
- Consumes: `ReaderState.ReadyPdf`, `PdfPageSource`, `AnnotationSurfaceState` (passed through, wired in Task 11).
- Produces:

```kotlin
@Composable
internal fun PdfVerticalScore(
    state: ReaderState.ReadyPdf,
    source: PdfPageSource,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    bottomContentPad: Dp = 0.dp,
    annotation: AnnotationSurfaceState? = null,
    autoFollowEnabled: Boolean = true,
)
```

- [ ] **Step 1: Build the surface**

Model it on `ReadyScore` (`ReaderScreen.kt:1068+`) and keep its proven structure:

- One vertically scrolling column of pages, each page a `Box` sized `pageWidthPt : pageHeightPt` scaled to the viewport width, separated by a small gap, on the reader's background color.
- Two-stage zoom, exactly as `ReadyScore` does it: a `scale` float state read inside a `graphicsLayer` block during the pinch, a separate `rasterScale` that the bitmaps were produced at, and one re-raster (`source.bitmap(index, widthPx = viewportWidth * scale)`) when the gesture ends. Do not re-render per frame.
- `source.setWindow(currentPage, radius = 1)` driven by the scroll position, so off-screen pages are evicted.
- A page whose bitmap is not ready yet draws as a plain page-colored rectangle — never a spinner per page, and never a layout jump, because the size comes from the page's point size, not from the bitmap.

- [ ] **Step 2: Branch the reader to it**

In `ReaderScreen.kt`, where the content currently switches on `layoutMode` for `ReaderState.Ready`, add the `ReaderState.ReadyPdf` branch: `ReaderLayoutMode.PAGE` → `PagedPdfScore` (Task 8), everything else → `PdfVerticalScore`. Horizontal is not reachable for a PDF because Task 5 removed it from the offered modes.

- [ ] **Step 3: Verify on device**

```bash
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
Scripts/android-build-reader-libs.sh
cd Android && ./gradlew :app:installDebug
adb shell am start -n com.keynumber.folino/.MainActivity
```

Import a MuseScore-exported PDF and open it. Check: pages render sharp at 1× and after a pinch; scrolling is smooth; staff lines are not blurred or doubled; memory does not climb without bound while scrolling a long document (`adb shell dumpsys meminfo com.keynumber.folino` before and after).

- [ ] **Step 4: Commit**

---

### Task 8: Paged PDF surface

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PagedPdfScore.kt`

**Interfaces:**
- Produces:

```kotlin
@Composable
internal fun PagedPdfScore(
    state: ReaderState.ReadyPdf,
    source: PdfPageSource,
    audioVm: ReaderAudioViewModel,
    readerVm: ReaderViewModel,
    pageTapHintDismissed: Boolean,
    onDismissPageTapHint: () -> Unit,
    autoFollowEnabled: Boolean = true,
    pageTurnButtonsVisible: Boolean = true,
    annotation: AnnotationSurfaceState? = null,
)
```

- [ ] **Step 1: Build the surface**

Mirror `PagedScore.kt` — `HorizontalPager` over `state.pageCount`, one fitted, centered page per pager page, the same pinch/pan handling, and the same `PageTapOverlay` + one-time hint wiring, so page-turn gestures and the tap zones behave identically to the score reader. The only substitution is the page content: `source.bitmap(...)` instead of `ScorePage`.

Drive `source.setWindow(pagerState.currentPage, radius = 1)` from the pager's settled page.

- [ ] **Step 2: Verify on device**

Install and switch the layout mode to page. Check: swipe turns pages; the tap zones turn pages; pinch zooms and the page re-rasterizes sharp on release; the mode picker offers only page and vertical.

- [ ] **Step 3: Commit**

---

### Task 9: Lift page anchoring into shared code

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/PageAnchoringCore.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/PageAnchoringCoreTests.swift` (create)

**Interfaces:**
- Consumes: `Domain.DrawingAnchor`, `Domain.DrawingAnchorKind`, `Domain.PageAnchor`, `Domain.InkStroke`, `InkStrokeCodec` (the neutral codec `AnnotationAnchoringCore` already uses).
- Produces `enum PageAnchoringCore`:
  - `static func pageIndex(forCentroid: CGPoint, pageFrames: [CGRect]) -> Int?`
  - `static func normalizeTransform(pageFrame: CGRect) -> CGAffineTransform?`
  - `static func displayTransform(pageFrame: CGRect) -> CGAffineTransform?`
  - `static func capture(strokes: [InkStroke], pageFrames: [CGRect]) -> [DrawingAnchor]`
  - `static func capturePage(strokes: [InkStroke], pageIndex: Int, pageFrame: CGRect) -> [DrawingAnchor]`
  - `static func partitionByPage(_ drawings: [DrawingAnchor], pageIndex: Int) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor])`
  - `static func displayTransforms(_ drawings: [DrawingAnchor], pageFrames: [CGRect]) -> [CGAffineTransform?]`

- [ ] **Step 1: Write the failing test**

```swift
import CoreGraphics
import Domain
import Testing
@testable import ReaderAnnotationCore

@Suite struct PageAnchoringCoreTests {
    private let frames = [
        CGRect(x: 0, y: 0, width: 100, height: 200),
        CGRect(x: 0, y: 220, width: 100, height: 200),
    ]

    @Test func centroidInsideAPageResolvesToThatPage() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 100), pageFrames: frames) == 0)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 300), pageFrames: frames) == 1)
    }

    /// A stroke landing in the gap belongs to the nearest page; an exact tie resolves upward.
    @Test func centroidInTheGapResolvesToTheNearerPage() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 205), pageFrames: frames) == 0)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 215), pageFrames: frames) == 1)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 210), pageFrames: frames) == 0)
    }

    @Test func noPagesMeansNoAnchor() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: .zero, pageFrames: []) == nil)
    }

    /// Normalization is a fraction of PAGE WIDTH in both axes, so zoom cancels out.
    @Test func normalizeAndDisplayAreInverses() throws {
        let frame = CGRect(x: 10, y: 220, width: 100, height: 200)
        let normalize = try #require(PageAnchoringCore.normalizeTransform(pageFrame: frame))
        let display = try #require(PageAnchoringCore.displayTransform(pageFrame: frame))
        let point = CGPoint(x: 60, y: 320)
        let round = point.applying(normalize).applying(display)
        #expect(abs(round.x - point.x) < 0.0001)
        #expect(abs(round.y - point.y) < 0.0001)
    }

    @Test func zeroWidthPageHasNoTransform() {
        #expect(PageAnchoringCore.normalizeTransform(pageFrame: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
    }

    @Test func partitionKeepsOffPageDrawings() {
        let onPage = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data([1]))
        let elsewhere = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data([2]))
        let split = PageAnchoringCore.partitionByPage([onPage, elsewhere], pageIndex: 1)
        #expect(split.onPage.count == 1)
        #expect(split.offPage.count == 1)
    }

    @Test func displayTransformsAreNilForOtherPages() {
        let drawing = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 5)), encodedDrawing: Data([1]))
        #expect(PageAnchoringCore.displayTransforms([drawing], pageFrames: frames) == [nil])
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Features/Reader
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Reader-Package/PageAnchoringCoreTests
```

Expected: FAIL — `PageAnchoringCore` does not exist.

- [ ] **Step 3: Move the geometry**

Create `PageAnchoringCore.swift` by transplanting the bodies of `PDFAnnotationAnchoring.pageIndex`, `.normalizeTransform`, `.displayTransform` and `.partitionByPage` verbatim — they are already PencilKit-free — and re-expressing `capture` / `capturePage` / `display` over the neutral `InkStroke` + `InkStrokeCodec`, the way `AnnotationAnchoringCore` does for musical anchors. Read `AnnotationAnchoringCore.swift:87-145` first and follow its normalize/denormalize helpers rather than writing new ones.

- [ ] **Step 4: Make the iOS type an adapter**

Rewrite `PDFAnnotationAnchoring` so each method converts PencilKit ↔ `InkStroke` (via the existing `InkStrokePencilKitBridge`) and delegates the geometry to `PageAnchoringCore`. Keep the type name and every existing call site — this is a refactor with no behavior change. Keep the "bake the transform into the points" step on the PencilKit side; that exists because PencilKit ignores a lingering per-stroke transform when computing renderable extent, and it must not be lost.

- [ ] **Step 5: Run the whole Reader package**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Features/Reader
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS, including the existing PDF annotation tests. Any change in those is a regression in the lift.

- [ ] **Step 6: Build the iOS app and commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

---

### Task 10: Page anchors over JNI

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift`
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/PdfAnnotationBridge.swift`
- Test: `Packages/Features/Reader/Tests/FolinoReaderJNITests/PdfAnnotationBridgeTests.swift` (create; match the directory the existing JNI tests live in)

**Interfaces:**
- Consumes: `PageAnchoringCore` (Task 9), `DrawingAnchorWire`, `StrokeTransformWire`, `RawInkStrokeWire` (existing).
- Produces:
  - `DrawingAnchorWire.anchorKind: Int32` — `0` musical, `1` page — and `pageIndex: Int32`, `-1` when musical.
  - `nativePdfAnnotationCapture(strokeBytes: Data, pageIndex: Int32, pageFrameBytes: Data) -> Data` → one `DrawingAnchorWire`
  - `nativePdfAnnotationDisplayTransforms(drawingsBytes: Data, pageFramesBytes: Data) -> Data` → `[StrokeTransformWire]` positionally aligned with the input; `sp == 0` marks "not on a visible page this frame"
  - `PageFrameWire { x: Double, y: Double, width: Double, height: Double }` and `PageFramesWire { frames: [PageFrameWire] }`

Reusing `StrokeTransformWire` matters: for a page anchor `sp` is the page frame's width and `(px, py)` its origin, which is exactly the `scale`-then-translate the existing dry overlay already applies with `canvas.concat`. The Compose placement code therefore needs no change at all.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
import Testing
@testable import FolinoReaderJNI

@Suite struct PdfAnnotationBridgeTests {
    private func frames() -> Data {
        PageFramesWire(frames: [
            PageFrameWire(x: 0, y: 0, width: 100, height: 200),
            PageFrameWire(x: 0, y: 220, width: 100, height: 200),
        ]).encodeToData()
    }

    @Test func captureProducesAPageAnchor() throws {
        // A two-point stroke whose centroid lands on page 1 (y 220...420).
        let stroke = RawInkStrokeWire(
            tool: 0, colorRGBA: 0xFF00_00FF, baseWidthSp: 1, opacity: 1,
            x: [40, 60], y: [300, 340], width: [1, 1], force: [1, 1], timeMillis: [0, 16],
        )
        let wire = try DrawingAnchorWire(decoding: nativePdfAnnotationCapture(
            strokeBytes: nativeEncodeInkStroke(rawBytes: stroke.encodeToData()),
            pageIndex: 1,
            pageFrameBytes: PageFrameWire(x: 0, y: 220, width: 100, height: 200).encodeToData(),
        ))
        #expect(wire.anchorKind == 1)
        #expect(wire.pageIndex == 1)
        #expect(!wire.encodedDrawing.isEmpty)
    }

    @Test func displayTransformScalesByPageWidthAndTranslatesToTheOrigin() throws {
        let drawing = DrawingAnchorWire.page(pageIndex: 1, encodedDrawing: Data([1, 2, 3]))
        let out = nativePdfAnnotationDisplayTransforms(
            drawingsBytes: [drawing].encodeToData(), pageFramesBytes: frames(),
        )
        let transforms = try [StrokeTransformWire](decoding: out)
        #expect(transforms.count == 1)
        #expect(transforms[0].sp == 100)
        #expect(transforms[0].px == 0)
        #expect(transforms[0].py == 220)
    }

    @Test func anchorOnAMissingPageIsMarkedUnplaceable() throws {
        let drawing = DrawingAnchorWire.page(pageIndex: 9, encodedDrawing: Data([1]))
        let transforms = try [StrokeTransformWire](decoding: nativePdfAnnotationDisplayTransforms(
            drawingsBytes: [drawing].encodeToData(), pageFramesBytes: frames(),
        ))
        #expect(transforms[0].sp == 0)
    }

    @Test func mismatchedInputsReturnEmpty() {
        #expect(nativePdfAnnotationDisplayTransforms(drawingsBytes: Data(), pageFramesBytes: frames()).isEmpty)
    }
}
```

Add the `DrawingAnchorWire.page(pageIndex:encodedDrawing:)` convenience constructor as part of the implementation. Copy the `RawInkStrokeWire` construction from the existing annotation bridge tests instead of inventing field values.

- [ ] **Step 2: Run it and watch it fail**

- [ ] **Step 3: Implement**

Extend `DrawingAnchorWire` with the two fields, defaulting `anchorKind` to `0` and `pageIndex` to `-1` in the memberwise init so every existing musical call site compiles unchanged. Then write the bridge, delegating all geometry to `PageAnchoringCore`.

Check `Domain.DrawingAnchor`'s decoder handles a wire round trip of `.page` anchors — the persisted JSON already supports `kind`, so nothing on the persistence side should need changing. If a round-trip test does not already exist in `Packages/Domain/Tests`, add one here.

- [ ] **Step 4: Run the tests to verify they pass**

- [ ] **Step 5: Rebuild the reader `.so` in the documented order and commit**

```bash
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
cd Android && ./gradlew :FolinoReaderAndroid:wireletGenerate   # confirm the real task name with ./gradlew tasks --all | rg -i wirelet
cd .. && Scripts/android-build-reader-libs.sh
cd Android && ./gradlew :app:assembleDebug
```

---

### Task 11: Annotation on the PDF surfaces

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfVerticalScore.kt`, `PagedPdfScore.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (annotation bundle for the PDF branch)
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt`

- [ ] **Step 1: Route the display path**

Where the dry overlay currently obtains transforms via `nativeAnnotationDisplayTransforms` (musical anchors, needing ssm reference points), branch on the reader's content: for a PDF, call `nativePdfAnnotationDisplayTransforms` with the current page frames instead. The output type is the same `List<StrokeTransformWire>`, so `AnnotationDryOverlay` needs no change.

- [ ] **Step 2: Route the capture path**

`AnnotationSurfaceState.onStrokeCaptured` for a PDF surface calls `nativePdfAnnotationCapture` with the page the stroke landed on — resolved from the centroid in vertical mode, and simply the visible page in paged mode.

- [ ] **Step 3: Keep the ink surface viewport-sized**

androidx.ink's front buffer fails past 65536px in a dimension, going invisible and risking an ANR. The annotation overlay must be sized to the viewport with the page transform applied inside it — never sized to the full zoomed content. Verify by zooming a long PDF to maximum and drawing.

- [ ] **Step 4: Verify on device**

Install, open a PDF, draw in vertical mode, leave and reopen the score, then cold-restart the app. Expected: strokes reappear at the same place and size each time, and at a different zoom than they were drawn at. Repeat in paged mode. Then erase part of a stroke and confirm it persists.

- [ ] **Step 5: Commit**

---

### Task 12: Background OMR parse

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfPlaybackState.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`

**Interfaces:**
- Consumes: `PdfScoreHandle.load(bytes)` and `PdfDiagnostic` (ssm plan Task 4), `nativeCanPlayNow` (Task 5).
- Produces:

```kotlin
internal sealed interface PdfPlaybackState {
    data object Idle : PdfPlaybackState
    data object Parsing : PdfPlaybackState
    data class Ready(val handle: PdfScoreHandle) : PdfPlaybackState
    data object Unavailable : PdfPlaybackState
}
```
plus `ReaderViewModel.pdfPlayback: StateFlow<PdfPlaybackState>`.

- [ ] **Step 1: Parse in the background**

After publishing `ReadyPdf`, launch a `Dispatchers.Default` job that installs the SMuFL metrics table (the parsed score needs it before playback prepares) and calls `PdfScoreHandle.load(bytes)`.

- On success: store `Ready(handle)`, publish `handle.score.raw` into `_scoreHandle` so the existing playback prepare path runs, and load parts for the mixer exactly as the `.mscz` path does.
- On failure or an empty result: `Unavailable`. Never surface it as `ReaderState.Error` — the document is already on screen.

Cancel the job and close the handle when the reader is retargeted or cleared.

- [ ] **Step 2: Gate the transport**

Transport controls, seek bar and the play FAB become enabled from `nativeCanPlayNow(canPlay = capabilities.canPlay, isPdfPlaybackReady = state is Ready)`. While `Parsing`, they render disabled rather than hidden, so the control does not appear mid-session and shift the layout.

- [ ] **Step 3: Verify on device**

Open a MuseScore-exported PDF. Expected: pages appear immediately; a moment later the transport enables; pressing play produces sound. Open a scanned/raster PDF: it displays, the transport stays disabled, and nothing is reported as an error.

- [ ] **Step 4: Commit**

---

### Task 13: Cursor and auto-follow on the PDF

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfVerticalScore.kt`, `PagedPdfScore.kt`

**Interfaces:**
- Consumes: `SheetMusicJNI.nativePdfCursorRect(geometryHandle, cursorBytes)` → `PdfRectWire` (top-left page points), `SheetMusicJNI.nativePdfPageSizes(geometryHandle)`, `ScoreCursorCodec.encode` (existing Kotlin codec), `nativeScrollOffsetKeepingInView` / `nativeScrollOffsetPinningSystemTop` (existing).

- [ ] **Step 1: Project the rect**

The geometry's page size and `PdfRenderer`'s page size are both PDF points and should agree. Compute `scale = renderedPageWidthPx / geometryPageWidthPt` and place the cursor at `pageOriginInContentSpace + rect * scale`. If the two page widths differ by more than 0.5pt, log a non-fatal via `CrashReporting.recordNonFatal` once per document and still draw — a silent mis-placement is worse than a reported one.

- [ ] **Step 2: Draw it**

Draw the cursor bar over the page bitmap with the same color and opacity the score reader's `PlaybackCursorOverlay` uses. Read the cursor flow in the leaf composable that draws it — not in the surface's outer body — or every playback tick re-composes the whole surface and scrolling breaks. This exact failure has bitten the iOS reader before; it is not hypothetical.

- [ ] **Step 3: Follow it**

Vertical: feed the projected rect's y-range into `nativeScrollOffsetPinningSystemTop` while playing and `nativeScrollOffsetKeepingInView` when paused, gated by `autoFollowEnabled` and the suspend-on-manual-gesture rule — the same wiring `ReadyScore` uses. Paged: when the cursor's page index changes and auto-follow is on, animate the pager to that page.

- [ ] **Step 4: Verify on device**

Play a PDF. Expected: the cursor sits on the right notes, advances smoothly, the page follows, and dragging the view during playback suspends the follow until the next play/seek.

- [ ] **Step 5: Commit**

---

### Task 14: Tap to seek, and diagnostics

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/pdf/PdfVerticalScore.kt`, `PagedPdfScore.kt`
- Modify: `Android/app/src/main/res/values/strings.xml` and `values-ja/strings.xml`

**Interfaces:**
- Consumes: `SheetMusicJNI.nativePdfHitTest(geometryHandle, pageIndex, x, y)` → `ScoreCursorWire` bytes, `audioVm.seek(...)` (existing).

- [ ] **Step 1: Wire the tap**

Convert the tap's content-space offset into page-local points (inverse of Task 13's projection), call `nativePdfHitTest`, and on a non-empty result decode it with `ScoreCursorCodec` and seek. An empty result does nothing — no toast, no flash.

The tap must not fire while the annotate tool is armed, matching the score surfaces' gate.

- [ ] **Step 2: The PDF playback caveat**

Mirror iOS's `PDFPlaybackNotice` (`Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPlaybackNotice.swift` + its presentation in `ReaderRootScreen.swift`) as a Material `AlertDialog`:

- Title: `reader.pdf.playback.notice.title`. Body: `reader.pdf.playback.notice.body` when the parse succeeded, `reader.pdf.playback.unavailable.body` when it failed. Reuse the en and ja values from the Reader's `Localizable.xcstrings` — do not write new copy.
- Two actions: a confirming **OK** that only closes it, and `reader.pdf.playback.notice.dismiss` ("don't show again") which sets the shared preference key `ReaderGlobalSettingsKey.pdfPlaybackNoticeDismissed` (`"readerPdfPlaybackNoticeDismissed"`, declared in `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`) so it stops presenting automatically. Store it through the existing Android reader-preferences path, under the same key string, so the two platforms agree on the setting's identity.
- Presented automatically at most once per opened document, and only while the flag is unset — the gate iOS uses is `isReady && !hasAutoShownPDFNotice && !dismissed`.
- Still reachable afterwards: tapping the PDF marker in the reader re-presents it, as the iOS badge does.

Note this is a caveat about OMR accuracy in general, not a per-diagnostic report — iOS never lists individual diagnostics in the UI, and neither does Android.

- [ ] **Step 3: Add the reader's PDF marker**

The reader has no PDF marker yet — Task 3 only added one to the library row. Add a `"PDF"` label to `ReaderTopBar` (`ReaderScreen.kt:1001+`), shown only for `ReaderState.ReadyPdf`, styled like the library row's label and clickable to re-present the caveat dialog. This is what makes the "don't show again" action safe: the explanation stays reachable after it is dismissed, exactly as on iOS.

- [ ] **Step 4: Verify on device**

Tap a note mid-page: playback jumps there. Tap empty margin: nothing happens. With the pen armed: a stroke is drawn and no seek fires. The caveat dialog appears once after the transport enables; "don't show again" suppresses it on the next open; the reader's PDF label still brings it back.

- [ ] **Step 5: Commit**

---

### Task 15: Full verification

- [ ] **Step 1: Swift package tests**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Packages/Domain
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
cd ../Features/Library
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
cd ../Reader
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: all green.

- [ ] **Step 2: iOS app build**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED. This is the gate on the Task 9 annotation lift and the Task 2 title-rule move.

- [ ] **Step 3: Android tests and release check**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-import-android/Android
./gradlew testDebugUnitTest
cd .. && Scripts/android-release-check.sh
```

Expected: green. `android-release-check.sh` is the gate that catches release-only crashes; do not skip it.

- [ ] **Step 4: Device pass on the Pixel 8a**

```bash
export PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"
cd Android && ./gradlew :app:installDebug
adb shell am start -n com.keynumber.folino/.MainActivity
```

Walk the whole feature: import a PDF from the picker → the row shows the PDF label → open it → vertical scroll, pinch, page mode, page turn → annotate in both modes → reopen and cold-restart to confirm persistence → wait for the transport to enable → play with the cursor following → tap to seek → confirm transpose / staff size / clef are absent from the inspector. Then repeat the import through another app's share sheet, and once with a scanned PDF to confirm the display-only fallback is silent.

- [ ] **Step 5: Report**

Report exactly what passed and what did not, with the commands' output. Do not claim the feature is verified on the strength of a build succeeding.

**Do not merge and do not push.** Merging to `main`, pushing either repository, and copying `java-generated/` + `jniLibs/` into the primary checkout are the user's calls.

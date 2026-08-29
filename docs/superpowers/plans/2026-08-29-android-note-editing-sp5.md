# Android Note Editing SP5 — Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Android's note editing actually save — the shared `EditorSessionCore.performSave()` path, a real
`ScoreFileWriting` on the JNI side, the Room row refresh, the autosave debounce and `onPause` flush, and the
sibling-`.mscz` policy — so an edit survives leaving the Reader and reopening the score.

**Architecture:** Nothing about *what* a save does moves: `EditorSessionCore.performSave()` already decides the
destination, captures the original, rebuilds the row and clears `isDirty`, and it is the same code iOS runs. SP5 fills
the two seams it writes through. `ScoreFileWriting` becomes `AndroidScoreWriter`, which encodes the score with ssm's
MSCX/MSCZ encoders inside the JNI image (the only place that can hold this `Score`) and refreshes the library row
through a new `@WireletProvided` method on `EditorHostFiles`. The *timer* stays where the run loop is — Kotlin — armed
from `EditSessionRelay`'s existing op funnel, the one choke point every applied edit already passes through.

**Tech Stack:** Swift 6.3 cross-compiled to Android (`FolinoEditorJNI`, a `.dynamic` product), swift-wirelet 0.5.0 /
Gradle plugin 0.3.2 for the JNI seams, swift-sheet-music 2.1.0 (`SheetMusicMSCX`, `SheetMusicLoader`), Kotlin +
Compose + Room on the host side.

**Spec:** `docs/superpowers/specs/2026-08-06-android-note-editing-design.md` — §8.2/§8.3/§8.4 (divergence and save
failure), §9 (testing), §11 (SP5's charter: "shared save path, Room row refresh, autosave debounce and `onPause`
flush, sibling-`.mscz` parity, instrumented smoke, device pass").

Predecessor plans: `…-sp0.md` … `…-sp4.md` in the same directory. SP4's SDD ledger is
`.superpowers/sdd/2026-08-15-android-note-editing-sp4/progress.md` (gitignored; lives only in this worktree).

## Status (2026-08-29)

Tasks 1-7 are **implemented, committed and verified** on `worktree-android-note-editing` — `557c4178` (seam),
`750a304a` (the save path and everything after it), `6aa866ed` (UUID score ids in the smoke test), `17bf3082` (the
flush measurement).

Verified:

- **Android JVM**: 59 + 221 + 2 + 8 tests, 0 failures.
- **Instrumented, on an arm64 `Pixel_6_Pro_API_36` emulator** (the user authorised the emulator for this session;
  the standing default is the physical Pixel): `:FolinoEditorAndroid:connectedDebugAndroidTest` 8/8 — the new
  `EditPersistenceTest` plus `EditSessionParityTest` and `EditingUiTest`, which keep their mirror-focused premise via
  the injected `NoAutosave`. `:app:connectedDebugAndroidTest` 70/70.
- **iOS**: the Editor package's 191 tests, since `EditorSessionCore.performSave` is the shared half.
- **Artifact**: arm64 and x86_64 `.so`s rebuilt from a cleaned `.build`, with `flushSave` / `refreshRow` /
  `didSaveAsSiblingMSCZ` confirmed present via `nm`.
- **Task 7's number, and the thing it caught.** On the emulator a save measured 21-24 ms and this plan's 120 ms line
  looked comfortably met. **On a Pixel 8a the same save is 160-230 ms** — the emulator was ~10x optimistic, and the
  main-thread encode this plan chose deliberately was not affordable after all. That is the one finding here worth
  carrying forward: performance judgements on Android need the device.

  The fix (commit `f4478734`) is `ConfinedEditSessionOps` — the editing session moved off Compose's main thread onto
  a dedicated single-thread executor, which is what `EditSessionRelay`'s own threading note already pointed at.
  `EditorBridge` is untouched and still single-threaded; only *which* thread changed. Main-thread cost is now
  0.14-0.32 ms per op and a save never lands there at all. The alternative considered and rejected was splitting
  `performSave` into prepare/write/complete phases on the shared core: correct, but it changes iOS-shared API to
  solve an Android-only threading problem.

  What the ~200 ms save *is* stayed partly unattributed: encode 59-88 ms, file write 0.7 ms, digest ~2 ms, and
  ~150 ms that is neither encoder options nor task priority nor the write. `EditPersistenceTest` records the dead
  ends so nobody re-runs them. It stopped mattering once the whole 200 ms left the main thread.

Still owed, and **only a person can do it**: the hands-on pass of Task 7 Step 4 on the physical Pixel — the six
scenarios plus the one thing SP5 cannot check for itself, whether the sibling-`.mscz` Snackbar reads right in place.
Task 7's separate diagnostic-log commit was not needed; the measurements live in the test instead.

Deviations from the plan as written, all small:

- Task 1's `RoomScoreRowRefresh.kt` in `:app` was not created. `RoomLibraryStore.sharedDatabase` is in a **private**
  companion object, so `:app` cannot reach the DAO; the row refresh is a public method on `RoomLibraryStore` instead,
  bound by method reference at the composition root. Fewer moving parts and no widened access.
- `EditAutosave` was introduced as an interface alongside `DebouncedAutosave`, matching `EditNatives`/`EditBridging`
  in the same module, so the relay's cadence obligations are assertable without a clock and the two mirror-focused
  instrumented suites can inject `NoAutosave`.
- `SheetMusicError` has no `unsupportedFormat` case; the unreachable branch throws `.unsupportedFeature` instead.

---

## Global Constraints

- **Worktree:** all work happens in `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing`
  on branch `worktree-android-note-editing`. Every git command uses `git -C <that absolute path>`. Never commit to the
  primary checkout.
- **Take `main` in before each task.** `git -C <worktree> merge main` (local main, no fetch needed). Resolve conflicts
  before starting the task's first step.
- **Logic parity is mandatory, UI placement is not.** No branch in `EditorBridge.swift`, `EditSessionRelay.kt` or
  `EditSessionController.kt` may decide anything about score content — a decision there is a rule Android has and iOS
  does not. Presentation (Snackbar vs. banner) follows Android idiom.
- **`EditorBridge` holds no concurrency.** No `Task { @MainActor … }`, no `MainActor`, no timers. An Android JNI process
  pumps no main runloop, so a main-actor Task is created and never runs (the bug `AnnotationSaveBridge.open` records).
  Async work is bridged to the synchronous JNI boundary with a `DispatchSemaphore`, exactly as `AnnotationSaveBridge.open`
  does, and only where the awaited work has no real suspension point.
- **Android deployment floor / schema:** `LibraryDatabase` is at `version = 2` and the app is **shipped** — a schema
  change needs a real `Migration`, never a destructive reset.
- **Access control:** new Swift symbols get no access modifier unless something outside the module references them.
- **Comment reflow budget:** 120 columns (`.swiftlint.yml` `line_length.warning`).
- **Toolchain for any `.so` rebuild:** `PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"`
  is exported by the build scripts themselves; do not use Xcode's Swift. Ordering is **Gradle wirelet codegen first,
  then the `.so`s, then `assembleDebug`**.
- **Never `uninstall` the app on the Pixel to make a build take.** Install over the top.

---

## What is already true (do not re-derive)

Read these before Task 1; they are the facts the plan is built on.

- `EditorSessionCore.performSave()` (`Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Persistence.swift`)
  is the shared save. It no-ops unless `isDirty`, computes `saveDestination(for:scoresDirectory:)`, captures the
  original (nil store on Android — skipped), calls `writer.write(score:to:format:)`, reads `fileFacts.hashAndSize(of:)`,
  rebuilds the whole `ScoreItem` from `itemToSave` plus the three save-derived fields, calls `writer.refreshRow(_:)`,
  and only then `markSaved()`. On any throw it keeps `isDirty == true` so the next tick retries (§8.4).
- `saveDestination` policy: `.mscx`/`.mscz` sources save **in place**; MusicXML / MXL / MIDI sources save as a
  **sibling `.mscz`** next to the original, and the returned tuple's `isSiblingCopy` is what sets
  `didSaveAsSiblingMSCZ` and swaps `localFileName` in the rebuilt row.
- `EditorBridge.beginSession` builds the core with `writer: UnimplementedScoreWriter()` — whose `write` / `refreshRow`
  `preconditionFailure`. **Nothing may reach it today**, which is why `discardSessionEdits()` deliberately skips the
  write-back half iOS performs.
- `stubRowPendingSave(id:localFileName:)` builds a deliberately partial `ScoreItem`: only `id` and `localFileName` are
  real. `performSave` copies **every** field of it into the row it hands `refreshRow`. **The stub is safe only because
  Android's `refreshRow` is a partial column update.** These two halves are one safety; the plan keeps them together.
- `EditorHostFiles` (`Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift`) is the
  `@WireletProvided` Kotlin seam, implemented by `EditorRoomFiles`. Its hex digest format is load-bearing: it must
  match what the importer wrote, or every save makes the library think it is looking at a new file.
- `EditSessionRelay.relay { … }` and `.replay(…)` are the only two paths an op takes; both end in `carryToMirror()`
  plus `host.requestRelayout()`. `close()` ends the mirror then the authoritative session. Ops run **synchronously on
  the Android main thread** and some return values the composition reads, so the bridge is single-threaded by
  construction.
- `LibraryDatabase` is built with `allowMainThreadQueries()` (`RoomLibraryStore.sharedDatabase`), so a synchronous
  Room write from a JNI call on the main thread is consistent with the rest of this app.
- **`score_records` has no `size_bytes` column**, and nothing on Android reads a size (`ScoreRecordWire` has no such
  field). SP3's seam doc predicted a *three*-column partial update; the correct Android answer is **two** —
  `local_file_name` and `content_hash`. Adding a third column for a value nothing reads would cost a real migration on
  a shipped schema. Task 1 corrects that doc.
- `:FolinoEditorAndroid` does **not** depend on `:FolinoLibraryAndroid` (they are siblings; `:app` wires them, and
  `:FolinoReaderAndroid` depends on the editor module). The row-refresh therefore crosses as a small interface declared
  in the editor module and implemented in `:app`, matching how `EditorRoomFiles` is already constructed there.
- `FolinoEditorJNI` has **no host test target** — it only builds under `FOLINO_ANDROID=1` cross-compilation. Its gate
  is the instrumented test in `:FolinoEditorAndroid/androidTest`, which already runs against the real `.so`s
  (`EditSessionParityTest`, `EditingUiTest`). Plan tests accordingly: JVM tests for Kotlin policy, instrumented tests
  for anything that crosses into Swift.
- `:app:connectedDebugAndroidTest` does **not** run `:FolinoEditorAndroid`'s androidTest. Use
  `:FolinoEditorAndroid:connectedDebugAndroidTest`. Connected tests uninstall the app when they finish — reinstall
  before any manual verification.

---

## File Structure

**Swift (`Packages/Features/Editor/Sources/FolinoEditorJNI/`)**

- `EditorAndroidSeams.swift` — **modify.** `EditorHostFiles` gains `refreshRow(...)`. `UnimplementedScoreWriter` is
  replaced by `AndroidScoreWriter` (encode + POSIX write + row refresh).
- `EditorBridge.swift` — **modify.** `beginSession` injects `AndroidScoreWriter`; new `flushSave()` op;
  `discardSessionEdits()` gains the write-back half; new `didSaveAsSiblingMSCZ` projection property; two doc
  corrections; one `PARITY(android)` marker deleted and one reworded.

**Kotlin — editor module (`Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/`)**

- `ScoreRowRefreshing.kt` — **create.** The one-method seam the editor module needs from whoever owns the library
  database, so the module stays independent of `:FolinoLibraryAndroid`.
- `EditorRoomFiles.kt` — **modify.** Takes a `ScoreRowRefreshing` and implements the new `refreshRow`.
- `DebouncedAutosave.kt` — **create.** The `EditAutosave` seam and its 2 s debounced implementation, on its own so a
  JVM test can drive the cadence on a virtual clock and the relay's own tests can use a recording fake — the same
  interface-plus-implementation shape `EditNatives`/`RealEditNatives` and `EditBridging`/`GeneratedEditBridging`
  already use in this module.
- `EditSessionRelay.kt` — **modify.** Arms the debounce in the op funnel; flushes on `close()`; new `flushPendingSave()`
  on `EditSessionOps`; `discardSessionEdits()` cancels the debounce first; two doc corrections.
- `EditSessionController.kt` — **modify.** `flushPendingSave()` passthrough; `didSaveAsSiblingMSCZ` folded into
  `EditUiState`.
- `EditProjection.kt` — **modify.** New `didSaveAsSiblingMSCZ` flow.

**Kotlin — library module (`Android/FolinoLibraryAndroid/…/RoomLibraryStore.kt`)** — **modify.** One partial-update
DAO query.

**Kotlin — app (`Android/app/src/main/kotlin/com/keynumber/folino/`)**

- `MainActivity.kt` — **modify.** Builds `EditorRoomFiles` over `RoomLibraryStore`'s new method (a SAM conversion —
  no adapter class needed, because `:app` is already the layer that constructs `RoomLibraryStore`); flushes the
  session on `ON_PAUSE`.

**Kotlin — Reader UI (`Android/FolinoReaderAndroid/src/main/…`)** — **modify.** `ReaderScreen.kt` gains the
sibling-`.mscz` Snackbar; `res/values*/strings.xml` gain its string in all five locales.

**Tests**

- `Android/FolinoEditorAndroid/src/test/kotlin/…/DebouncedAutosaveTest.kt` — **create** (JVM).
- `Android/FolinoEditorAndroid/src/test/kotlin/…/EditSessionRelayTest.kt` — **modify** (JVM).
- `Android/FolinoEditorAndroid/src/androidTest/kotlin/…/EditPersistenceTest.kt` — **create** (instrumented; the §9
  round-trip smoke).

**Docs** — `docs/engineering/ios-android-parity.md` is **generated**; it changes only via `Scripts/parity-report.py`.

---

## Task 1: The Room row refresh, end to end in Kotlin

Build the host half first, against a fake, so Task 2's Swift side has a real seam to call rather than a promise.

**Files:**
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/ScoreRowRefreshing.kt`
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditorRoomFiles.kt`
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` (the
  `ScoreRecordDao` interface around line 41, and one public method on `RoomLibraryStore` itself)
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt:1137-1146` (`EditorBridgeVMFactory`)
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift` (doc only, in this task)
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditorRoomFilesTest.kt` (create)

**Interfaces:**
- Produces:
  - `interface ScoreRowRefreshing { fun refreshAfterSave(id: String, localFileName: String, contentHash: String) }`
    in package `com.keynumber.folino.editor`.
  - `class EditorRoomFiles(private val rows: ScoreRowRefreshing) : EditorHostFiles` — the no-arg constructor is gone;
    every construction site passes a refresher.
  - `ScoreRecordDao.refreshAfterSave(id: String, localFileName: String, contentHash: String)` and
    `RoomLibraryStore.refreshRowAfterSave(id: String, localFileName: String, contentHash: String)`.
- Consumes: nothing from later tasks. `EditorHostFiles` is the wirelet-generated interface; the `refreshRow` member it
  will grow arrives in Task 2, so **this task does not yet add an `override` for it** — see Step 3's note.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Write the failing test**

Create `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditorRoomFilesTest.kt`:

```kotlin
package com.keynumber.folino.editor

import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test

/**
 * [EditorRoomFiles] is the editor's file seam: the digest and size a save derives, plus the two library columns it
 * writes back. The digest assertions pin the FORMAT (lowercase hex SHA-256), which has to match what the importer
 * wrote or every save makes the library think it is looking at a new file.
 */
class EditorRoomFilesTest {

    private class RecordingRows : ScoreRowRefreshing {
        val calls = mutableListOf<Triple<String, String, String>>()
        override fun refreshAfterSave(id: String, localFileName: String, contentHash: String) {
            calls += Triple(id, localFileName, contentHash)
        }
    }

    @Test
    fun `sha256Hex is lowercase hex of the file's bytes`() {
        val file = File.createTempFile("editor-room-files", ".bin")
        file.writeBytes("abc".toByteArray())
        val hex = EditorRoomFiles(RecordingRows()).sha256Hex(file.absolutePath)
        // The published SHA-256 of "abc".
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex)
    }

    @Test
    fun `a missing file has no digest and no size rather than throwing`() {
        val files = EditorRoomFiles(RecordingRows())
        val absent = File.createTempFile("editor-room-files", ".bin").also { it.delete() }.absolutePath
        assertEquals("", files.sha256Hex(absent))
        assertEquals(0L, files.fileSize(absent))
    }

    @Test
    fun `refreshRow forwards exactly the three save-derived values`() {
        val rows = RecordingRows()
        EditorRoomFiles(rows).refreshRow("score-id", "Etude.mscz", "deadbeef")
        assertEquals(1, rows.calls.size)
        assertEquals(Triple("score-id", "Etude.mscz", "deadbeef"), rows.calls.single())
    }

    @Test
    fun `fileSize is the file's byte count`() {
        val file = File.createTempFile("editor-room-files", ".bin")
        file.writeBytes(ByteArray(1234))
        assertTrue(EditorRoomFiles(RecordingRows()).fileSize(file.absolutePath) == 1234L)
    }
}
```

- [ ] **Step 3: Run it and watch it fail**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest --tests '*EditorRoomFilesTest*'
```

Expected: compilation failure — `Unresolved reference: ScoreRowRefreshing`, and `refreshRow` unresolved on
`EditorRoomFiles`.

**Note on `refreshRow`:** `EditorHostFiles` is generated by the wirelet Gradle plugin from the Swift protocol, and the
Swift side does not declare `refreshRow` until Task 2. So in this task `EditorRoomFiles.refreshRow` is a **plain
method with no `override`**; Task 2 adds the `override` keyword once the generated interface carries it. That
ordering is deliberate — it keeps this task's Kotlin green on its own, and it makes Task 2's codegen step
self-verifying (the `override` will not compile until the regenerated interface really has the member).

- [ ] **Step 4: Create the seam**

`Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/ScoreRowRefreshing.kt`:

```kotlin
package com.keynumber.folino.editor

/**
 * The one thing a save needs from whoever owns the library database: put the two columns a save derives back on the
 * score's row.
 *
 * An interface here rather than a dependency on `:FolinoLibraryAndroid` for the reason [EditSessionHost] is one — the
 * editor module is a sibling of the library module, not a consumer of it, and `:app` is the layer that sees both.
 *
 * **A partial update of exactly these columns, never a whole-row write.** `EditorBridge.stubRowPendingSave` builds
 * the `ScoreItem` an Android session carries with only `id` and `localFileName` real, and
 * `EditorSessionCore.performSave` rebuilds the row from every field of it — so a whole-row Android writer would push
 * those placeholders over the user's real title, tags and dates. The stub and this narrowness are one safety; do not
 * widen either without the other.
 *
 * Two values, not three: iOS also refreshes `sizeBytes`, and Android's `score_records` has no such column and nothing
 * that reads a size. Adding one for a value nobody reads would cost a real migration on a shipped schema.
 */
fun interface ScoreRowRefreshing {
    /**
     * @param id the score's row id (the `ScoreItemID` UUID string the session was opened with).
     * @param localFileName the file the score now lives in — different from the one it opened with exactly when a
     *   non-MuseScore source was saved as a sibling `.mscz`.
     * @param contentHash lowercase hex SHA-256 of that file, in the format the importer writes.
     */
    fun refreshAfterSave(id: String, localFileName: String, contentHash: String)
}
```

- [ ] **Step 5: Give `EditorRoomFiles` the refresher**

Replace the class declaration and doc in `EditorRoomFiles.kt` (keep `sha256Hex` / `fileSize` bodies exactly as they
are) with:

```kotlin
/**
 * The Kotlin half of the editor's file seam.
 *
 * The digest format is load-bearing: it has to be the same lowercase hex SHA-256 the importer wrote, or a save makes
 * the library think it is looking at a new file. That is why this mirrors the importer's digest rather than picking
 * its own encoding.
 *
 * The row refresh is delegated rather than performed here: this module does not depend on `:FolinoLibraryAndroid`,
 * so `:app` supplies the [ScoreRowRefreshing] that owns the database — see that interface for why the update is
 * partial.
 */
class EditorRoomFiles(private val rows: ScoreRowRefreshing) : EditorHostFiles {

    fun refreshRow(id: String, localFileName: String, contentHash: String) =
        rows.refreshAfterSave(id, localFileName, contentHash)
```

- [ ] **Step 6: Run the test and watch it pass**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest --tests '*EditorRoomFilesTest*'
```

Expected: 4 tests, 0 failures.

- [ ] **Step 7: Add the DAO query**

In `RoomLibraryStore.kt`, inside `interface ScoreRecordDao` (after `upsert`):

```kotlin
    /**
     * The two columns a note-edit save derives, written back without touching the rest of the row.
     *
     * A partial update rather than an `upsert`, because the editor's session carries a deliberately partial
     * `ScoreItem` (`EditorBridge.stubRowPendingSave`) — a whole-row write from that side would blank the user's
     * title, tags and dates. See `ScoreRowRefreshing` in `:FolinoEditorAndroid`, which is the seam this backs.
     */
    @Query(
        "UPDATE score_records SET local_file_name = :localFileName, content_hash = :contentHash WHERE id = :id",
    )
    fun refreshAfterSave(id: String, localFileName: String, contentHash: String)
```

- [ ] **Step 8: Expose it on `RoomLibraryStore`**

`sharedDatabase` lives in `RoomLibraryStore`'s **private** companion object, so `:app` cannot reach the DAO directly
and must not be given a way to. Add a public method to `RoomLibraryStore` instead — it already holds
`private val dao` — right after `scoresDirectoryPath()`:

```kotlin
    /**
     * Puts the two columns a note-edit save derives back on a score's row, leaving the rest of it alone.
     *
     * Not part of `LibraryStore` (the `@WireletProvided` seam the Swift library store is injected with): this one is
     * called by the EDITOR's file seam, through `ScoreRowRefreshing` in `:FolinoEditorAndroid`, which `:app` binds to
     * this method. Keeping it off the wire interface is what keeps the editor from acquiring a whole library store it
     * has no business holding.
     *
     * Runs on the calling thread, which for a save is the main thread — see this class's note on
     * `allowMainThreadQueries()`. One `UPDATE` by primary key, once per debounced save.
     */
    fun refreshRowAfterSave(id: String, localFileName: String, contentHash: String) =
        dao.refreshAfterSave(id, localFileName, contentHash)

- [ ] **Step 9: Wire it at the composition root**

In `MainActivity.kt`, `EditorBridgeVMFactory` currently reads:

```kotlin
        EditorBridgeViewModel.create(EditorRoomFiles()) as T
```

A factory `object` cannot reach a `Context`, so make it a class the Activity constructs. Replace the object (and
rewrite its doc comment, which currently states "It needs no `Context`") with:

```kotlin
/**
 * Builds the editor's native bridge view model.
 *
 * It needs a `Context` now. [EditorRoomFiles] still does plain `java.io.File` I/O over the paths the caller supplies,
 * but a save also puts the two columns it derives back on the library row, and that is Room — bound here to
 * `RoomLibraryStore.refreshRowAfterSave`, since `:app` is the only module that sees both sides.
 */
class EditorBridgeVMFactory(context: Context) : ViewModelProvider.Factory {
    private val rows = com.keynumber.folino.library.RoomLibraryStore(context.applicationContext)

    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        // A SAM conversion of the method reference — `ScoreRowRefreshing` is a `fun interface`.
        EditorBridgeViewModel.create(EditorRoomFiles(rows::refreshRowAfterSave)) as T
}
```

(`RoomLibraryStore` is spelled fully qualified because that is how `MainActivity` already refers to it — see lines
359, 608, 1025.)

and at the use site (around `MainActivity.kt:686`):

```kotlin
                val editBridgeVm: EditorBridgeViewModel =
                    viewModel(factory = remember(context) { EditorBridgeVMFactory(context) })
```

- [ ] **Step 10: Correct the seam doc that predicted three columns**

In `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift`, the paragraph beginning
"**Android's `refreshRow` will be a partial update…**" says it writes `localFileName`, `contentHash`, `sizeBytes`.
Replace the sentence naming those three with:

```swift
/// exactly the two columns Android's library actually stores of the three a save derives — `local_file_name` and
/// `content_hash` — keyed on the row's id. `sizeBytes` is deliberately not among them: `score_records` has no such
/// column and nothing on Android reads a size, and adding one for a value nobody reads would cost a real migration
/// on a shipped schema.
```

- [ ] **Step 11: Build the Android host and run the editor module's JVM tests**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest :app:assembleDebug
```

Expected: BUILD SUCCESSFUL, 0 test failures.

- [ ] **Step 12: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "feat(android): give the editor a library-row refresh seam"
```

---

## Task 2: The Swift writer — a save that actually writes

**Files:**
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorAndroidSeams.swift`
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` (`beginSession` ~line 190-210;
  `endSession` ~line 213; new `flushSave()` op)
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditorRoomFiles.kt` (add `override`)
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt`
  (`GeneratedEditBridging` passthrough + the `EditBridging` interface)

**Interfaces:**
- Consumes: `ScoreRowRefreshing` and `EditorRoomFiles(rows:)` from Task 1.
- Produces:
  - Swift protocol member `func refreshRow(id: String, localFileName: String, contentHash: String)` on
    `EditorHostFiles`.
  - `struct AndroidScoreWriter: ScoreFileWriting` (replaces `UnimplementedScoreWriter`).
  - `EditorBridge.flushSave()` — a synchronous `@WireletExpose` op, no return value.
  - Kotlin `EditBridging.flushSave()` and its `GeneratedEditBridging` passthrough `vm.flushSave()`.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Extend the `@WireletProvided` protocol**

In `EditorAndroidSeams.swift`, add to `EditorHostFiles` (after `fileSize`):

```swift
    /// Puts the two columns a save derives back on the library row: the file the score now lives in, and its digest.
    ///
    /// A partial update, never a whole-row write — see the note on `AndroidScoreWriter.refreshRow` and on
    /// `EditorBridge.stubRowPendingSave` for the safety the two halves make together.
    func refreshRow(id: String, localFileName: String, contentHash: String)
```

- [ ] **Step 3: Replace the trapping writer with a real one**

In `EditorAndroidSeams.swift`, delete `UnimplementedScoreWriter` entirely (including its `swiftlint:disable`
comments) and put this in its place — keeping the parts of the old doc that record *why* the row refresh is partial,
since that reasoning is still live:

```swift
/// Android's `ScoreFileWriting`: the MSCX/MSCZ encode plus the write, and the library row refresh behind the Kotlin
/// seam.
///
/// The encode happens **in this image**, because that is where the `Score` is (spec §3 — a `Score` cannot cross
/// between the process's two `SheetMusicCore` copies, only bytes can). The encoders and their defaults are the same
/// ones iOS reaches through `LiveScoreFileGateway.saveScore`: no options, `score.mscx` as the archive's main file, so
/// a file written on Android is byte-comparable with one written on iOS from the same score.
///
/// **`refreshRow` is a partial update of the two columns Android stores.** `EditorBridge.stubRowPendingSave` builds
/// the session's `ScoreItem` with only `id` and `localFileName` real, and `EditorSessionCore.performSave` rebuilds
/// the row from EVERY field of it before calling this — so a whole-row Android writer would push those placeholders
/// over the user's real title, tags and dates. iOS keeps its whole-row repository write; the seam is per-platform by
/// construction. The two halves are one safety; do not change either without the other.
///
/// `@unchecked Sendable` for the reason `HostFileFacts` is: the wrapped `@WireletProvided` proxy is a thin JNI
/// forwarder that is not intrinsically `Sendable`, and the only holder is one `EditorSessionCore` driven from one JNI
/// call at a time.
struct AndroidScoreWriter: ScoreFileWriting, @unchecked Sendable {
    let files: EditorHostFiles

    /// `async` by conformance only; the body never suspends. The encode and the write run on whichever thread the JNI
    /// op arrived on — see `EditorBridge.flushSave`, which is where that thread is chosen and why.
    // swiftlint:disable:next async_without_await
    func write(_ score: Score, to url: URL, format: ScoreFormat) async throws {
        switch format {
        case .mscx:
            try MSCXEncoder.encode(score, to: url)
        case .mscz:
            try MSCZWriter.write(score: score, to: url)
        case .musicXML, .mxl, .midi, .pdf:
            // Unreachable by construction: `EditorSessionCore.saveDestination` answers only `.mscx` or `.mscz`, and
            // every other source saves as a sibling `.mscz`. Thrown rather than trapped because `performSave`
            // catches it into "stay dirty and retry", which is the right answer for a case that cannot happen.
            throw SheetMusicError.unsupportedFormat(format.canonicalExtension)
        }
    }

    // swiftlint:disable:next async_without_await
    func refreshRow(_ item: ScoreItem) async throws {
        files.refreshRow(
            id: item.id.rawValue.uuidString,
            localFileName: item.localFileName,
            contentHash: item.contentHash,
        )
    }
}
```

**If `SheetMusicError.unsupportedFormat` does not exist** with that spelling, use whichever `SheetMusicError` case
takes a message and name the format in it — do **not** use `SheetMusicError.invalidEdit`, which is the one error this
feature deliberately swallows as benign. Check with:

```bash
grep -rn "case unsupportedFormat\|public enum SheetMusicError" -A 30 \
  ~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicCore/ | head -40
```

- [ ] **Step 4: Inject it, and add the flush op**

In `EditorBridge.swift`, in `beginSession`, replace:

```swift
            writer: UnimplementedScoreWriter(),
```

with:

```swift
            writer: AndroidScoreWriter(files: files),
```

Then add, immediately after `endSession()`:

```swift
    /// Writes the session's pending edits, if any. A no-op when nothing changed since the last save.
    ///
    /// The debounce that decides WHEN this runs is Kotlin's, for the reason `EditorSessionCore.performSave`'s own doc
    /// gives — a timer belongs where the run loop is, and this image has none. `DebouncedAutosave` is the Android
    /// counterpart of iOS's `EditorViewModel.scheduleAutosave`.
    ///
    /// Synchronous, and blocking, on purpose. `performSave` is `async`; a `@WireletExpose` op cannot await, so the
    /// `Task` is joined with a `DispatchSemaphore` exactly as `AnnotationSaveBridge.open` does. The same argument for
    /// why that cannot deadlock holds here: the save's only nominal suspension point is
    /// `originals?.captureOriginalIfNeeded`, and Android builds the core with no originals store, so the awaited work
    /// is a straight-line encode and write with nothing to starve the cooperative pool on.
    ///
    /// It blocks the caller's thread — the Android main thread — for the length of an MSCZ encode. That is deliberate
    /// rather than tolerated: every op in this file already runs synchronously on that thread and each one triggers a
    /// full relayout, so the core is single-threaded by construction and moving just the save off it would be a data
    /// race, not an optimization. The 2 s debounce is what keeps the cost off the typing path.
    @WireletExpose
    public func flushSave() {
        guard let core else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await core.performSave()
            semaphore.signal()
        }
        semaphore.wait()
        sync()
    }
```

Add `import Dispatch` to the file's import block if it is not already there.

Also update `endSession`'s doc, which currently says the flush is "SP5's job; there is nothing to flush yet":

```swift
    /// Drops the session. The host flushes any pending save first — see `EditSessionRelay.close`, which calls
    /// `flushSave()` before this. Ending without that flush loses whatever the debounce had not yet written.
```

- [ ] **Step 5: Add the Kotlin passthrough**

In `EditSessionRelay.kt`, add `fun flushSave()` to the `EditBridging` interface (next to `endSession()`), and to
`GeneratedEditBridging`:

```kotlin
    override fun flushSave() = vm.flushSave()
```

Nothing calls it yet — Task 3 does. Add the `override` keyword to `EditorRoomFiles.refreshRow` in the same commit,
since the regenerated `EditorHostFiles` now carries the member.

- [ ] **Step 6: Regenerate the wirelet bindings, then the `.so`s**

Ordering matters — codegen first, `.so`s second, app third. Building `.so`s first in a changed-seam tree yields
libraries whose JNI surface does not match the generated Kotlin.

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:generateWireletProvidedInterfacesMain \
  :FolinoEditorAndroid:generateWireletObservableViewModelsMain
```

- [ ] **Step 7: Rebuild the editor `.so`s from clean**

`.build` staleness in this package has produced a heap-corrupting mixed-object `.so` before (see
`reference_android_native_drift`); a seam change is exactly the case that mixes old and new objects.

```bash
rm -rf /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/Editor/.build
```

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Scripts/android-build-editor-libs.sh
```

Expected: `libFolinoEditorJNI.so` staged into `Android/FolinoEditorAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/`, and
regenerated bindings under `src/main/java-generated/`.

- [ ] **Step 8: Verify the new symbol really made it into the artifact**

`BUILD SUCCEEDED` does not prove the edit was compiled.

```bash
nm -a /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/FolinoEditorAndroid/src/main/jniLibs/arm64-v8a/libFolinoEditorJNI.so | grep -c flushSave
```

Expected: a non-zero count. If it is 0, the build did not pick the edit up — clean and rebuild before continuing.

- [ ] **Step 9: Build the app and run every editor JVM test**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest :app:assembleDebug
```

Expected: BUILD SUCCESSFUL, 0 failures.

- [ ] **Step 10: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "feat(android): write edited scores to disk and refresh the library row"
```

---

## Task 3: The autosave debounce, and the flushes that bracket a session

**Files:**
- Create: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/DebouncedAutosave.kt`
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt`
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionController.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (the editing block around line 668-712)
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/DebouncedAutosaveTest.kt` (create)
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditSessionRelayTest.kt` (modify)

**Interfaces:**
- Consumes: `EditBridging.flushSave()` from Task 2.
- Produces:
  - `interface EditAutosave { fun arm(); fun flushNow(); fun cancel() }`.
  - `class DebouncedAutosave(scope: CoroutineScope, delayMillis: Long = 2_000L, save: () -> Unit) : EditAutosave`.
  - `EditSessionRelay(bridge, host, natives = RealEditNatives, audition = NoteAuditioning {}, autosave: EditAutosave)`
    — the constructor grows one required trailing parameter. It is required rather than defaulted because a default
    would have to construct a `CoroutineScope` here, and the relay has no business owning one.
  - `EditSessionOps.flushPendingSave()` and `EditSessionController.flushPendingSave()`.
  - New Gradle test dependency on `:FolinoEditorAndroid`: `kotlinx-coroutines-test:1.9.0`, matching the module's
    existing `kotlinx-coroutines-android:1.9.0`. Test-scope only; nothing ships.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Write the failing debounce test**

Create `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/DebouncedAutosaveTest.kt`:

```kotlin
package com.keynumber.folino.editor

import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Test

/**
 * The autosave cadence, on a virtual clock. What is asserted here is coalescing and ordering — the two properties
 * that decide whether a burst of pad taps costs one encode or twenty, and whether leaving a session can outrun the
 * write it owes.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DebouncedAutosaveTest {

    @Test
    fun `a burst of edits collapses into one save`() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves++ }

        repeat(20) {
            autosave.arm()
            scope.advanceTimeBy(50L)
        }
        assertEquals(0, saves, "nothing may be written while the user is still typing")

        scope.advanceTimeBy(2_001L)
        assertEquals(1, saves)
    }

    @Test
    fun `flushNow writes immediately and cancels the pending tick`() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves++ }

        autosave.arm()
        autosave.flushNow()
        assertEquals(1, saves, "a flush is synchronous — the session may be torn down on the next line")

        scope.advanceTimeBy(5_000L)
        assertEquals(1, saves, "the armed tick must not fire a second write after the flush")
    }

    @Test
    fun `flushNow with nothing armed still writes`() = runTest {
        var saves = 0
        val autosave = DebouncedAutosave(TestScope(testScheduler), delayMillis = 2_000L) { saves++ }

        autosave.flushNow()

        // The Swift side answers "nothing to do" when the session is clean, so an unconditional call is correct here
        // and keeps this class from having to track dirtiness a second time.
        assertEquals(1, saves)
    }

    @Test
    fun `cancel drops the pending write without performing it`() = runTest {
        var saves = 0
        val scope = TestScope(testScheduler)
        val autosave = DebouncedAutosave(scope, delayMillis = 2_000L) { saves++ }

        autosave.arm()
        autosave.cancel()
        scope.advanceTimeBy(5_000L)

        assertEquals(0, saves)
    }
}
```

`:FolinoEditorAndroid` currently has only `testImplementation("junit:junit:4.13.2")` and there is no version catalog
in this repo (versions are literals in each `build.gradle.kts`). Add, next to it:

```kotlin
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
```

1.9.0 because that is the module's own `kotlinx-coroutines-android` version — a mismatched test artifact resolves the
runtime up or down under the hood and produces failures that look like the code's.

- [ ] **Step 3: Run it and watch it fail**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest --tests '*DebouncedAutosaveTest*'
```

Expected: `Unresolved reference: DebouncedAutosave`.

- [ ] **Step 4: Write the debounce**

Create `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/DebouncedAutosave.kt`:

```kotlin
package com.keynumber.folino.editor

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * When the session's pending edits get written.
 *
 * An interface for the same reason [EditNatives] and [EditBridging] are ones: [EditSessionRelay] is the piece under
 * test, and its cadence obligations (arm on every op, flush before the session ends, cancel on a discard) are
 * assertable without a clock only if the thing it drives can be recorded. The shipping implementation is
 * [DebouncedAutosave].
 */
interface EditAutosave {
    /** (Re)starts the quiet period. Called once per op, from the relay's funnel. */
    fun arm()

    /** Writes now, synchronously, and drops whatever was armed. */
    fun flushNow()

    /** Drops the pending write without performing it. */
    fun cancel()
}

/**
 * The editing session's autosave cadence — Android's half of what iOS's `EditorViewModel.scheduleAutosave` does.
 *
 * The policy of a save (where, in what format, what the row becomes afterwards) is the shared
 * `EditorSessionCore.performSave`; what lives here is only the timer, which belongs where the run loop is. The
 * `FolinoEditorJNI` image has no run loop at all, so this is the piece that cannot be shared.
 *
 * **[save] runs on the caller's thread — the main thread.** It reaches into `EditorBridge`, which is single-threaded
 * by construction: every op runs synchronously on the main thread and mutates the same non-`Sendable`
 * `EditorSessionCore`. Moving the write to `Dispatchers.IO` would be a data race against the next pad tap, not a
 * responsiveness win. The 2 s debounce is what keeps the encode off the typing path; [flushNow] is the one place the
 * cost is taken deliberately.
 *
 * @param delayMillis the quiet period after the last edit. 2 s, matching iOS's `scheduleAutosave` and the Reader's
 *   annotation debounce.
 */
class DebouncedAutosave(
    private val scope: CoroutineScope,
    private val delayMillis: Long = 2_000L,
    private val save: () -> Unit,
) : EditAutosave {
    private var pending: Job? = null

    override fun arm() {
        pending?.cancel()
        pending = scope.launch {
            delay(delayMillis)
            save()
        }
    }

    /**
     * Writes now, and drops whatever was armed.
     *
     * Synchronous rather than launched: every caller is about to do something the write must precede — end the
     * session, discard the edits, or let the process be backgrounded — and a coroutine queued behind that is a
     * coroutine that may never run. The Swift side answers "nothing to do" when the session is clean, so calling it
     * unconditionally is correct and keeps dirtiness tracked in exactly one place.
     */
    override fun flushNow() {
        pending?.cancel()
        pending = null
        save()
    }

    /** For a discard, which is about to make the pending write wrong. */
    override fun cancel() {
        pending?.cancel()
        pending = null
    }
}
```

- [ ] **Step 5: Run the test and watch it pass**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest --tests '*DebouncedAutosaveTest*'
```

Expected: 4 tests, 0 failures.

- [ ] **Step 6: Write the failing relay test**

`EditSessionRelayTest.kt` already has `FakeBridge`, `FakeNatives`, `FakeHost`, `FakeAuditioning` and a `Fixture` that
bundles them (`private class Fixture(bridge, natives, host)` with `val relay = EditSessionRelay(bridge, host, natives,
audition)` and `fun open()`). Extend those three things:

1. `FakeBridge` gains the new bridging member and a lifecycle log, so ordering is assertable:

```kotlin
    /** `endSession` and `flushSave` in the order the relay called them — the property `close()` has to get right. */
    val lifecycleLog = mutableListOf<String>()
    var flushes = 0

    override fun flushSave() {
        flushes += 1
        lifecycleLog.add("flushSave")
    }
```

and change the existing `endSession` to record itself:

```kotlin
    override fun endSession() {
        opened = false
        lifecycleLog.add("endSession")
    }
```

2. A recording autosave next to the other fakes:

```kotlin
/** Records what the relay asks of its autosave. The cadence itself is [DebouncedAutosaveTest]'s subject; what is
 *  asserted here is that the relay asks at all, and in the right order relative to the session's teardown — which is
 *  why the flush lands in the bridge's own [FakeBridge.lifecycleLog] rather than in a second list. */
private class FakeAutosave(private val lifecycleLog: MutableList<String>) : EditAutosave {
    var arms = 0
    var flushes = 0
    var cancels = 0
    override fun arm() { arms += 1 }
    override fun flushNow() {
        flushes += 1
        lifecycleLog.add("flushSave")
    }
    override fun cancel() { cancels += 1 }
}
```

3. `Fixture` holds one and passes it:

```kotlin
    val autosave = FakeAutosave(bridge.lifecycleLog)
    val relay = EditSessionRelay(bridge, host, natives, audition, autosave)
```

Then the three new cases:

```kotlin
    @Test fun everyOpArmsTheAutosave() {
        val f = Fixture()
        f.open()

        f.relay.inputPitch("C")
        f.relay.deleteSelection()
        f.relay.undo()

        // The funnel is the choke point — iOS's op funnel arms unconditionally too, and for the same reason its
        // doc gives: the timer must not be skippable for one op and not another.
        assertEquals(3, f.autosave.arms)
    }

    @Test fun anOpBeforeTheSessionOpensArmsNothing() {
        val f = Fixture()

        f.relay.inputPitch("C")

        assertEquals(0, f.autosave.arms)
    }

    @Test fun closeFlushesBeforeItEndsTheSession() {
        val f = Fixture()
        f.open()

        f.relay.close()

        // Ending first would drop whatever the debounce had not yet written: `endSession` takes the authoritative
        // session — and the score it holds — away.
        assertEquals(listOf("flushSave", "endSession"), f.bridge.lifecycleLog)
    }

    @Test fun aDiscardCancelsThePendingWriteRatherThanPerformingIt() {
        val f = Fixture()
        f.open()

        f.relay.inputPitch("C")
        f.relay.discardSessionEdits()

        // The armed write is for the score the user has just thrown away. The write-back of the UNWOUND score is
        // `EditorBridge.discardSessionEdits`'s own, on the Swift side.
        assertEquals(1, f.autosave.cancels)
    }

    @Test fun flushPendingSaveBeforeTheSessionOpensDoesNothing() {
        val f = Fixture()

        f.relay.flushPendingSave()

        assertEquals(0, f.autosave.flushes)
    }
```

- [ ] **Step 7: Run it and watch it fail**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest --tests '*EditSessionRelayTest*'
```

Expected: compilation failure on the new `EditSessionRelay` constructor parameters.

- [ ] **Step 8: Arm the debounce from the funnel**

In `EditSessionRelay.kt`:

1. Add the constructor parameter (trailing, after `audition`, so the existing positional call sites keep working):

```kotlin
class EditSessionRelay(
    private val bridge: EditBridging,
    private val host: EditSessionHost,
    private val natives: EditNatives = RealEditNatives,
    private val audition: NoteAuditioning = NoteAuditioning {},
    private val autosave: EditAutosave,
) : EditSessionOps {
```

2. Arm from the two funnels — `relay { }` and `replay(…)`, which between them are every op — not from
`carryToMirror()`. `carryToMirror()` returns early when the op applied no frames, and undo/redo (which do move the
score) go through `replay` and emit no frames at all, so arming there would miss exactly the ops that matter most.

In `relay { }`, immediately after `op()`:

```kotlin
    private fun relay(op: () -> Unit) {
        if (!isOpen) return
        op()
        // Unconditional, from the one place no op can skip. iOS arms in its own op funnel for the reason
        // `EditorViewModel+Ops`'s doc gives — "the autosave timer can never be skipped for one op and not another" —
        // and an op that changed nothing costs only a timer tick that `performSave` then answers with "not dirty".
        autosave.arm()
```

In `replay(mirror, local)`, immediately after `local()`:

```kotlin
        local()
        autosave.arm()
```

Do not add a third arming site.

3. `close()` flushes first:

```kotlin
    /** Ends both sides. Safe to call twice; `nativeEndEditSession` is a no-op for a handle with no session. */
    override fun close() {
        if (!isOpen) return
        // Before anything is torn down: the debounce may be holding an unwritten edit, and `endSession` drops the
        // authoritative session that owns it. iOS flushes in `EditorViewModel.endSession` for the same reason.
        autosave.flushNow()
        natives.endEditSession(host.scoreHandle())
        bridge.endSession()
        isOpen = false
    }
```

4. `discardSessionEdits()` cancels first — insert as its first statement after the `isOpen` guard:

```kotlin
        // The armed write is for a score the user has just decided to throw away. Cancel rather than flush; Task 4
        // gives the discard its own write-back of the UNWOUND score.
        autosave.cancel()
```

5. Add the flush op to `EditSessionOps` and implement it:

```kotlin
    /** Writes any pending edit now, without ending the session. The Activity calls this on `onPause`. */
    fun flushPendingSave()
```

```kotlin
    override fun flushPendingSave() {
        if (!isOpen) return
        autosave.flushNow()
    }
```

- [ ] **Step 9: Add the controller passthrough**

In `EditSessionController.kt`, next to `end()`:

```kotlin
    /**
     * Writes any pending edit now. Called from the Reader's `ON_PAUSE`, which is the last moment Android guarantees
     * before a process can be killed — the same place `AnnotationSaveBridge`'s flush is driven from.
     */
    fun flushPendingSave() = relay.flushPendingSave()
```

Also fix `end()`'s ordering assumption if needed: it already calls `relay.close()`, which now flushes.

- [ ] **Step 10: Drive the flush from the Activity**

In `MainActivity.kt`, inside the editing block (right after the `DisposableEffect(editController)` that ends the
session), add:

```kotlin
                // The last moment Android guarantees before the process can be killed. `DisposableEffect` above
                // covers leaving the Reader; this covers being backgrounded while still in it, and mirrors how the
                // annotation save is flushed.
                val editLifecycleOwner = LocalLifecycleOwner.current
                DisposableEffect(editLifecycleOwner, editController) {
                    val observer = LifecycleEventObserver { _, event ->
                        if (event == Lifecycle.Event.ON_PAUSE) editController.flushPendingSave()
                    }
                    editLifecycleOwner.lifecycle.addObserver(observer)
                    onDispose { editLifecycleOwner.lifecycle.removeObserver(observer) }
                }
```

Add the imports `androidx.lifecycle.Lifecycle`, `androidx.lifecycle.LifecycleEventObserver`,
`androidx.lifecycle.compose.LocalLifecycleOwner` if they are not already present (check — the file may already
observe the lifecycle elsewhere; reuse the existing observer if so rather than adding a second).

And in the same file's `remember(editBridgeVm, readerVm, audioVm, editScope) { … }` block, give the relay its
autosave. `bridging` is already constructed on the line above, so the lambda can close over it:

```kotlin
                    val relay = EditSessionRelay(
                        bridging,
                        readerVm,
                        audition = NoteAuditioning(audioVm::playNotePreview),
                        // The Reader screen's scope, so the pending write dies with the screen rather than with the
                        // process. `close()` flushes on the way out, so nothing is lost when it does.
                        autosave = DebouncedAutosave(editScope) { bridging.flushSave() },
                    )
```

Note this is a named argument, so `natives` keeps its `RealEditNatives` default.

- [ ] **Step 11: Update the androidTest construction sites**

`EditingUiTest.kt:108,110` and `EditSessionParityTest.kt:124,233` construct `EditorRoomFiles()` and
`EditSessionRelay(bridge, host, RealEditNatives)`. Both now need arguments:

```kotlin
            bridge = GeneratedEditBridging(EditorBridgeViewModel.create(EditorRoomFiles { _, _, _ -> }))
            relay = EditSessionRelay(
                bridge, host, RealEditNatives,
                // These suites drive the relay directly and assert on the mirror, not on the file. A no-op autosave
                // keeps a debounce from firing a save into the middle of a fingerprint assertion; the save path has
                // its own suite (`EditPersistenceTest`).
                autosave = object : EditAutosave {
                    override fun arm() {}
                    override fun flushNow() {}
                    override fun cancel() {}
                },
            )
```

`EditorRoomFiles { _, _, _ -> }` works because `ScoreRowRefreshing` is a `fun interface`. Do not add a Room dependency
to these tests.

**`EditPersistenceTest` (Task 6) is the exception** — it needs a real autosave and a recording refresher, and builds
them itself.

- [ ] **Step 12: Run the tests and the build**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest :app:assembleDebug
```

Expected: BUILD SUCCESSFUL, 0 failures.

- [ ] **Step 13: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "feat(android): debounce the editing autosave and flush it on pause"
```

---

## Task 4: Discard writes the unwound score back

Today Android's discard is an in-memory unwind, which was correct only because nothing was ever on disk. With Task 2
landed, an edit the user discards may already be in the file, so the unwind has to be written back — the iOS ordering,
minus the parts Android has no store for.

**Files:**
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` (`discardSessionEdits`, ~line 461-478;
  the `revertToOriginal` parity marker, ~line 480)
- Modify: `docs/engineering/ios-android-parity.md` (regenerated, never hand-edited)
- Test: `Android/FolinoEditorAndroid/src/androidTest/kotlin/com/keynumber/folino/editor/EditPersistenceTest.kt`
  (created in Task 6; this task's own gate is the existing instrumented suite plus the device pass)

**Interfaces:**
- Consumes: `AndroidScoreWriter` (Task 2), `EditSessionRelay`'s `autosave.cancel()` on discard (Task 3).
- Produces: no new symbols.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Give the discard its write-back**

In `EditorBridge.swift`, delete the parity marker above `discardSessionEdits`:

```swift
    // PARITY(android): discard does not persist — the unwound score is not written back, because Android's edit
    //   sessions have no writer yet (SP5). Delete this marker when SP5 lands and the flush is wired.
```

and replace the method and its doc with:

```swift
    /// Throws this session's edits away: unwind the command stack back to where the session opened, then write that
    /// score back over whatever the autosave had already put on disk.
    ///
    /// The ordering is iOS's (`EditorViewModel.discardSessionEdits`), and each step is load-bearing:
    ///
    /// - Mark discarded even when there is nothing to unwind — leaving without edits must not deposit a stack the
    ///   user has just declined.
    /// - Only write if the unwind actually landed back where the session opened. It can fail to (an adopted
    ///   session's stack reaches back past this session's start), and half-unwound bytes are worse than the edits.
    /// - `markDirtyForDiscardFlush()` before the save, because the unwind itself does not dirty the session and
    ///   `performSave` no-ops on a clean one — without it, the file would keep the edits that were just discarded.
    ///
    /// The host cancels its armed autosave before calling this (`EditSessionRelay.discardSessionEdits`): the pending
    /// write is for the score being thrown away, and it must not land after this one.
    ///
    /// What iOS does and this cannot: take back an original its first save captured. Android has no originals store —
    /// see `revertToOriginal()` below and its parity marker.
    ///
    /// Produces no relay frames: like undo, the unwind drives `ScoreEditSession` directly rather than through
    /// `apply`. The host must therefore reconcile the mirror by fingerprint afterwards rather than by replaying
    /// frames — see `EditSessionRelay.discardSessionEdits`.
    @WireletExpose
    public func discardSessionEdits() {
        guard let core else { return }
        core.markSessionDiscarded()
        guard core.sessionHasEdits else {
            sync()
            return
        }
        core.unwindSessionEdits()
        guard !core.sessionHasEdits else {
            sync()
            return
        }
        core.markDirtyForDiscardFlush()
        flushSave()
    }
```

`flushSave()` ends with its own `sync()`, so the two early returns are the only ones that need theirs.

- [ ] **Step 3: Reword the `revertToOriginal` parity marker**

It currently ends "…and SP5's writer to restore through." SP5 has landed the writer, so that clause is now false.
Replace the marker with:

```swift
    // PARITY(android): revert to original — needs an Android `ScoreOriginalStore` (sidecar copy + restore), the
    //   `original*` Room columns and a migration, and `RevertPolicy`'s warnings bridged across. The writer it would
    //   restore through exists (`AndroidScoreWriter`); what is missing is the original to restore. Delete this
    //   marker when that lands.
```

Update `revertToOriginal()`'s own doc in the same pass: the sentence "Android has no sidecar copy, no `original*`
columns in the Room row, and no writer to restore through" must lose its last clause, and "The op and its call site
exist now so the placement is settled and SP5 fills the body" must stop naming SP5 as the filler — SP5 is this plan
and it does not build an originals store.

- [ ] **Step 4: Regenerate the parity ledger**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing
```

```bash
python3 Scripts/parity-report.py
```

Expected: `docs/engineering/ios-android-parity.md` loses the "discard does not persist" row and the
"revert to original" row's text changes. The `parity-ledger` pre-commit hook fails the commit if the file drifted, so
this step is not optional.

- [ ] **Step 5: Rebuild the `.so`s and verify the artifact**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Scripts/android-build-editor-libs.sh
```

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest :app:assembleDebug
```

Expected: BUILD SUCCESSFUL, 0 failures.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "feat(android): write the unwound score back when edits are discarded"
```

---

## Task 5: The sibling-`.mscz` notice, and the docs a save invalidates

A MusicXML / MXL / MIDI score's edits land in a **new file** next to it. iOS says so once, in a banner; Android says
so once, in a Snackbar — the same content, the platform's own placement. Two doc paragraphs elsewhere describe a world
with no save in it and are now wrong.

**Files:**
- Modify: `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` (new projection property + `sync()`)
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditProjection.kt`
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionController.kt`
  (`EditUiState` + the sixth combine group)
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (Scaffold at ~934)
- Modify: `Android/FolinoReaderAndroid/src/main/res/values/strings.xml` and `values-ja`, `values-ko`, `values-zh-rCN`,
  `values-zh-rTW`
- Modify: `Android/FolinoEditorAndroid/src/main/kotlin/com/keynumber/folino/editor/EditSessionRelay.kt` (doc only)
- Test: `Android/FolinoEditorAndroid/src/test/kotlin/com/keynumber/folino/editor/EditSessionControllerTest.kt`

**Interfaces:**
- Consumes: the projection plumbing established in SP4.
- Produces: `EditProjection.didSaveAsSiblingMSCZ: StateFlow<Boolean>`, `EditUiState.didSaveAsSiblingMSCZ: Boolean`.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Publish the flag from the bridge**

In `EditorBridge.swift`, next to `sessionHasEdits` / `canRevertToOriginal` (inside the same
`swiftformat:disable redundantType` block, since the explicit `: Bool` is load-bearing for jextract):

```swift
    /// Whether a save has written this score's edits to a NEW file — a sibling `.mscz` next to a MusicXML / MXL /
    /// MIDI source, which is the only format that can carry a note edit. Latched by `EditorSessionCore`, so it stays
    /// true for the rest of the session and the host can show its notice once.
    public internal(set) var didSaveAsSiblingMSCZ: Bool = false
```

and in `sync()`, alongside the other end-of-session reads:

```swift
        didSaveAsSiblingMSCZ = core.didSaveAsSiblingMSCZ
```

- [ ] **Step 3: Carry it through the projection**

In `EditProjection.kt`, add:

```kotlin
    val didSaveAsSiblingMSCZ: StateFlow<Boolean>
```

and in `GeneratedEditBridging`'s conformance, `override val didSaveAsSiblingMSCZ get() = vm.didSaveAsSiblingMSCZ`
(match the file's existing spelling for the other `Bool` flows).

In `EditSessionController.kt`, add the field to `EditUiState`:

```kotlin
    /** Whether this session's edits were written to a NEW file — a sibling `.mscz` next to a source format that
     *  cannot carry a note edit. Latched, so the notice can be shown once and then ignored. */
    val didSaveAsSiblingMSCZ: Boolean = false,
```

and to the `SessionEnd` group — it already carries three fields and `combine` takes up to five, so extend it rather
than adding a seventh group:

```kotlin
        val sessionEnd = combine(
            projection.sessionHasEdits,
            projection.canRevertToOriginal,
            projection.sessionEndModeKind,
            projection.didSaveAsSiblingMSCZ,
        ) { sessionHasEdits, canRevertToOriginal, endModeKind, savedAsSibling ->
            SessionEnd(
                sessionHasEdits, canRevertToOriginal, EditSessionEndMode.fromKind(endModeKind), savedAsSibling,
            )
        }
```

with `SessionEnd` gaining `val didSaveAsSiblingMSCZ: Boolean`, and the `_ui.update` block gaining
`didSaveAsSiblingMSCZ = ending.didSaveAsSiblingMSCZ,`.

- [ ] **Step 4: Add the string in all five locales**

`Android/FolinoReaderAndroid/src/main/res/values/strings.xml`:

```xml
    <string name="editor_notice_saved_as_mscz">Edits are saved as a MuseScore (.mscz) copy next to the original file.</string>
```

`values-ja`:

```xml
    <string name="editor_notice_saved_as_mscz">編集内容は元のファイルの隣に MuseScore (.mscz) 形式のコピーとして保存されます。</string>
```

`values-ko`:

```xml
    <string name="editor_notice_saved_as_mscz">편집 내용은 원본 파일 옆에 MuseScore(.mscz) 사본으로 저장됩니다.</string>
```

`values-zh-rCN`:

```xml
    <string name="editor_notice_saved_as_mscz">编辑内容将保存为原文件旁的 MuseScore (.mscz) 副本。</string>
```

`values-zh-rTW`:

```xml
    <string name="editor_notice_saved_as_mscz">編輯內容將儲存為原始檔案旁的 MuseScore (.mscz) 副本。</string>
```

These are the exact strings from `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`
(`editor.notice.savedAsMscz`) — copied rather than re-translated, so the two platforms say the same thing.

- [ ] **Step 5: Show it once, from the Reader's Scaffold**

In `ReaderScreen.kt`, add a `SnackbarHostState` near the other `remember`s above the `Scaffold(` at line 934, give the
Scaffold a `snackbarHost = { SnackbarHost(snackbarHost) }`, and drive it from the latched flag:

```kotlin
    val snackbarHost = remember { SnackbarHostState() }
    val siblingNotice = stringResource(R.string.editor_notice_saved_as_mscz)
    // Latched on the Swift side, so this fires once per session rather than once per save. Android's Snackbar in
    // place of iOS's top banner: same sentence, this platform's own surface.
    LaunchedEffect(editing.didSaveAsSiblingMSCZ) {
        if (editing.didSaveAsSiblingMSCZ) snackbarHost.showSnackbar(siblingNotice)
    }
```

- [ ] **Step 6: Correct the two docs a save invalidates**

In `EditSessionRelay.kt`, `open()`'s doc paragraph beginning "**The fingerprint check at open is not paranoia…**"
argues from "SP3/SP4 ship no save at all". Replace its middle with:

```
     * **The fingerprint check at open is not paranoia; it is the normal second session.** Ending a session does not
     * revert the mirror ("the score keeps whatever the session last wrote" — ssm's own words). With SP5 the two
     * usually agree at reopen, because this side parses a file that now HOLDS the edits — which is exactly why the
     * check has to stay: the cases where they do not agree are a save that failed (§8.4 leaves the session dirty and
     * the file behind), a discard whose write-back did not land, a double open, and a file replaced underneath us.
     * Resyncing here pushes the file-parsed score into the handle, which is also the correct semantics: the file is
     * the truth, and anything the mirror holds beyond it was never persisted.
```

And delete the **third** parity marker, the one sitting directly above `class EditSessionRelay` — the last of SP5's
four clauses comes true with this task:

```kotlin
// PARITY(android): note editing — the session and the relay are here and proven on a physical device, but nothing
//   drives them yet: the contextual app bar, pad, callout and caret overlay are SP4; the save path, autosave, the
//   onPause flush and the sibling-.mscz policy are SP5. Delete this marker when SP5 lands.
```

Regenerate the ledger afterwards, as Task 4 did:

```bash
python3 /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Scripts/parity-report.py
```

Expected: `docs/engineering/ios-android-parity.md` loses the "note editing" row. Only the `revert to original` row
should remain of the three this feature added — check that, since it is the whole point of the ledger not rotting.

In `EditorAndroidSeams.swift`, the `HostFileFacts` doc is still accurate — leave it. The `UnimplementedScoreWriter`
doc is gone with the type (Task 2).

- [ ] **Step 7: Extend the controller test**

In `EditSessionControllerTest.kt`, add `didSaveAsSiblingMSCZ` to `FakeProjection` as a `MutableStateFlow(false)` and:

```kotlin
    @Test
    fun `the sibling-mscz notice reaches the ui state`() = runTest {
        val projection = FakeProjection()
        val controller = EditSessionController(FakeRelay(), projection, backgroundScope)

        projection.didSaveAsSiblingMSCZ.value = true
        runCurrent()

        assertTrue(controller.ui.value.didSaveAsSiblingMSCZ)
    }
```

Match the file's existing scope/dispatcher idiom — the suite currently uses a plain `CoroutineScope` for the
synchronous fields and asserts the collected ones separately; follow whichever shape the neighbouring tests use for a
collected field.

- [ ] **Step 8: Rebuild and run**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Scripts/android-build-editor-libs.sh
```

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:testDebugUnitTest :FolinoReaderAndroid:testDebugUnitTest :app:assembleDebug
```

Expected: BUILD SUCCESSFUL, 0 failures.

- [ ] **Step 9: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "feat(android): tell the user when edits land in a sibling .mscz"
```

---

## Task 6: The instrumented round-trip smoke

Spec §9's Android gate: "Enter edit mode, write a bar, delete a note, undo twice, redo, leave, reopen — assert the
file round-trips." This is the only automated test that exercises the Swift writer, since `FolinoEditorJNI` has no
host test target.

**Files:**
- Create: `Android/FolinoEditorAndroid/src/androidTest/kotlin/com/keynumber/folino/editor/EditPersistenceTest.kt`
- Modify: `Android/FolinoEditorAndroid/src/androidTest/kotlin/com/keynumber/folino/editor/EditSessionParityTest.kt`
  (doc comment on `reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging`, whose stated premise SP5 invalidates)
- Test fixture: the `parity.mscz` asset `EditSessionParityTest.stagedFixture` already copies into
  `context.filesDir/Scores/<name>.mscz`. Reuse it.

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: no production symbols.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Read the existing instrumented setup**

```bash
sed -n '1,145p' /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/FolinoEditorAndroid/src/androidTest/kotlin/com/keynumber/folino/editor/EditSessionParityTest.kt
```

The pieces the new test reuses, by name: `onMain { }` (every relay/bridge call goes through it — the relay's contract
is one thread and that thread is Compose's main thread), `stagedFixture(name)` → `Pair<File, File>` of the staged
`.mscz` and the `Scores` dir, `openRig(file, scoresDir, scoreId)` → `Rig(bridge, host, relay)`, `TestHost`, the
`relaysToClose` / `hostsToRelease` teardown lists, `firstRestID()`, the `QUARTER` / `EIGHTH` duration constants, and
`SheetMusicJNI.nativeScoreFingerprint(handle)`.

**Also read `reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging` (around line 215).** Its premise is "SP3 saves
nothing", and it asserts `resyncCount == 1` at reopen. Task 3 Step 11 gave that suite a no-op `EditAutosave`, so
`relay.close()` flushes nothing and the test keeps passing unchanged — but its **doc comment is now wrong**. Update it
in this task:

```kotlin
    /**
     * Closing a session does not revert the mirror, so a second session that parses a file the first one's edits
     * never reached finds the handle already ahead of it. The fingerprint check in `open()` is what catches that,
     * and this is the test that fails if someone removes it as redundant.
     *
     * This suite injects a no-op autosave (see [openRig]), which is what makes that state reachable on purpose. In
     * production SP5 writes on close and the two usually agree at reopen — but "usually" is the point: a save that
     * failed (§8.4), a discard whose write-back did not land, and a file replaced underneath us all land right here.
     */
```

- [ ] **Step 3: Write the failing test**

Create `EditPersistenceTest.kt`. It is a sibling of `EditSessionParityTest`, so copy that file's `TestHost`, `Rig`,
`onMain`, `tearDown`, `stagedFixture`, `firstRestID` and `QUARTER` verbatim (they are `private` to that class) and
change only `openRig`, which here injects a **real** `DebouncedAutosave` and a **recording** `ScoreRowRefreshing`:

```kotlin
package com.keynumber.folino.editor

import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import java.io.File
import kotlinx.coroutines.MainScope
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Spec §9's Android persistence gate: an edit made in a session is on disk once the session ends, a fresh session
 * over the same file starts from it, and a discard takes the file back.
 *
 * On device rather than on the JVM because the writer is Swift: `FolinoEditorJNI` is a cross-compiled `.dynamic`
 * product with no host test target, so this is the only automated place the encode and the write are exercised at
 * all.
 *
 * It asserts on FILE BYTES and on a REOPENED session's fingerprint, never on the projection. The projection would go
 * on saying whatever the in-memory core believes even if the write silently did nothing, which is the exact failure
 * this test exists to catch.
 *
 * Unlike [EditSessionParityTest], this one uses the real [DebouncedAutosave] — the save path IS the subject — and
 * drives it through [EditSessionRelay.flushPendingSave] / `close()` rather than waiting out the 2 s debounce.
 */
class EditPersistenceTest {
    /** Records what a save asked the library row to become, so the Room-facing half is assertable without Room. */
    private class RecordingRows : ScoreRowRefreshing {
        val calls = mutableListOf<Triple<String, String, String>>()
        override fun refreshAfterSave(id: String, localFileName: String, contentHash: String) {
            calls += Triple(id, localFileName, contentHash)
        }
    }

    private class Rig(
        val bridge: GeneratedEditBridging,
        val host: TestHost,
        val relay: EditSessionRelay,
        val rows: RecordingRows,
        val file: File,
        val scoresDir: File,
        val scoreId: String,
    )

    // …TestHost / onMain / relaysToClose / hostsToRelease / tearDown / stagedFixture / firstRestID / QUARTER,
    // copied from EditSessionParityTest…

    private fun openRig(name: String, existing: Pair<File, File>? = null): Rig {
        val (file, scoresDir) = existing ?: stagedFixture(name)
        val handle = SheetMusicJNI.nativeLoadScore(file.readBytes())
        assertNotEquals(0L, handle)
        val host = TestHost(handle)
        val rows = RecordingRows()
        lateinit var bridge: GeneratedEditBridging
        lateinit var relay: EditSessionRelay
        var opened: OpenResult? = null
        onMain {
            bridge = GeneratedEditBridging(EditorBridgeViewModel.create(EditorRoomFiles(rows)))
            relay = EditSessionRelay(
                bridge, host, RealEditNatives,
                autosave = DebouncedAutosave(MainScope()) { bridge.flushSave() },
            )
            relaysToClose.add(relay)
            hostsToRelease.add(host)
            opened = relay.open(file.path, scoresDir.path, name)
        }
        assertEquals(OpenResult.OPENED, opened)
        return Rig(bridge, host, relay, rows, file, scoresDir, name)
    }

    /** Writes one quarter-note C into the first bar — the smallest edit that changes the score. */
    private fun writeANote(rig: Rig) = onMain {
        rig.relay.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID())))
        rig.relay.armDuration(QUARTER)
        rig.relay.inputPitch("C")
    }

    @Test fun anEditReachesTheFileWhenTheSessionEnds() {
        val rig = openRig("persist-basic")
        val before = rig.file.readBytes()

        writeANote(rig)
        onMain { rig.relay.close() }

        assertNotEquals(
            "the edit never reached the file",
            before.toList(), rig.file.readBytes().toList(),
        )
        // And the library row was told where the bytes are now, with a digest in the importer's format.
        val (id, localFileName, contentHash) = rig.rows.calls.last()
        assertEquals("persist-basic", id)
        assertEquals(rig.file.name, localFileName)
        assertTrue("digest must be lowercase hex SHA-256: $contentHash", contentHash.matches(Regex("[0-9a-f]{64}")))
    }

    @Test fun aReopenedSessionStartsFromTheSavedScore() {
        val rig = openRig("persist-reopen")
        writeANote(rig)
        var edited = 0L
        onMain {
            edited = rig.bridge.scoreFingerprint()
            rig.relay.close()
        }

        // A FRESH handle off the file on disk, so nothing but the file can carry the edit across.
        val reopened = openRig("persist-reopen", existing = rig.file to rig.scoresDir)
        var reopenedLocal = 0L
        onMain { reopenedLocal = reopened.bridge.scoreFingerprint() }

        assertEquals("the file does not hold the score the session ended on", edited, reopenedLocal)
        assertEquals("a saved reopen must need no resync", 0, reopened.relay.resyncCount)
        onMain { reopened.relay.close() }
    }

    @Test fun aDiscardPutsTheOpeningScoreBackOnDisk() {
        val rig = openRig("persist-discard")
        var opening = 0L
        onMain { opening = rig.bridge.scoreFingerprint() }

        writeANote(rig)
        onMain { rig.relay.flushPendingSave() }
        assertNotEquals("the edit must be on disk before the discard, or this proves nothing", 0, rig.rows.calls.size)

        onMain {
            rig.relay.discardSessionEdits()
            rig.relay.close()
        }

        val reopened = openRig("persist-discard", existing = rig.file to rig.scoresDir)
        var afterDiscard = 0L
        onMain { afterDiscard = reopened.bridge.scoreFingerprint() }
        assertEquals(
            "a discard has to take the FILE back to where the session opened, not only the memory",
            opening, afterDiscard,
        )
        onMain { reopened.relay.close() }
    }

    @Test fun undoAndRedoRoundTripThroughTheFile() {
        val rig = openRig("persist-undo")
        writeANote(rig)
        var expected = 0L
        onMain {
            rig.relay.inputPitch("D")
            rig.relay.undo()
            rig.relay.undo()
            rig.relay.redo()
            expected = rig.bridge.scoreFingerprint()
            rig.relay.close()
        }

        val reopened = openRig("persist-undo", existing = rig.file to rig.scoresDir)
        var actual = 0L
        onMain { actual = reopened.bridge.scoreFingerprint() }
        assertEquals("the file must hold exactly the score the session ended on", expected, actual)
        onMain { reopened.relay.close() }
    }
}
```

Two things to watch when this first runs:

- **Fingerprints, not bytes, for the reopen assertions.** Two `.mscz` archives of the same score should be
  byte-identical (`ZipWriter` writes no timestamps), but `stableFingerprint` is what the design actually promises and
  what a resync compares — assert on it. Byte comparison is used only in the first test, where all that is claimed is
  "the file changed at all".
- **`MainScope()` in `openRig`** is deliberate: the debounce never fires in this test (every save is a `flushNow`
  through `flushPendingSave` / `close`), so the scope only has to exist. Do not leak it — it is process-scoped and
  the test ends with the process.

- [ ] **Step 4: Run it and watch the interesting parts fail**

Ensure the Pixel is connected (`adb devices`), then:

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:connectedDebugAndroidTest --tests '*EditPersistenceTest*'
```

Expected: 4 tests. They should pass, because Tasks 1-4 implemented the behaviour they assert — this is the point in
the plan where the Swift writer is exercised for the first time, so a failure here is a genuine SP5 bug. Debug it
rather than weakening the assertion. The two most likely real failures, and what each means:

- `anEditReachesTheFileWhenTheSessionEnds` fails with the bytes unchanged → the flush never reached
  `performSave`, or `performSave` returned early. Check that `close()` calls `autosave.flushNow()` **before**
  `bridge.endSession()` (a session already dropped has nothing to save), and that `isDirty` was true.
- `aDiscardPutsTheOpeningScoreBackOnDisk` fails → `markDirtyForDiscardFlush()` is missing from
  `EditorBridge.discardSessionEdits`, and `performSave` no-opped on a session the unwind left clean.

- [ ] **Step 5: Run the whole instrumented suite for the editor module**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :FolinoEditorAndroid:connectedDebugAndroidTest
```

Expected: `EditSessionParityTest`, `EditingUiTest` and `EditPersistenceTest` all green. Note that a connected test run
**uninstalls the app** when it finishes.

- [ ] **Step 6: Run everything else that could have regressed**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  testDebugUnitTest
```

```bash
xcodebuild test -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Folino.xcodeproj \
  -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -skipPackagePluginValidation -only-testing:EditorCoreTests -only-testing:EditorTests
```

The iOS run is not ceremony: `EditorSessionCore+Persistence.swift` is shared, and Task 4's discard reasoning is about
its contract. If `Folino.xcodeproj` does not exist in the worktree, generate it first with `env -C <worktree> xcodegen`
(no `--spec`/`--project` flags — see the worktree memory for why).

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "test(android): assert an edit survives the session that made it"
```

---

## Task 7: Device pass, and the one number worth measuring

The final gate for this feature is the user on the physical Pixel (spec §9). This task prepares the build, states
exactly what to try, and measures the one cost the design deliberately took on the main thread.

**Files:**
- Modify (temporarily): `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift` — a timing log around
  `flushSave`, reverted before the task's final commit.

- [ ] **Step 1: Take `main` in**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

- [ ] **Step 2: Instrument the flush**

In `flushSave()`, around the semaphore wait:

```swift
        let started = DispatchTime.now().uptimeNanoseconds
        // …existing body…
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("[EditorSave] flush took \(String(format: "%.1f", elapsedMs)) ms")
```

This is a diagnostic commit that gets reverted in Step 6 — it exists because the plan chose to run the encode on the
main thread, and that choice is only defensible with a number.

- [ ] **Step 3: Build, reinstall, and hand it over**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Scripts/android-build-editor-libs.sh
```

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android/gradlew \
  -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Android \
  :app:installDebug
```

Install over the existing app — never uninstall. Then start the log tail:

```bash
adb logcat -s Folino:V System.out:V | grep -i EditorSave
```

- [ ] **Step 4: The device checklist (hand to the user, verbatim)**

Open BumbleBee (a `.mscz`) and, in the note-editing session:

1. Write a bar of notes, wait ~3 s, leave the Reader, reopen the score. **The notes are still there.**
2. Write a note, then immediately press back without waiting. **The note is still there on reopen** (the flush on
   close, not the debounce, is what saves it).
3. Write a note, then background the app with the home gesture, then return. **The note is still there** (`onPause`).
4. Write two notes, undo twice, redo once, leave, reopen. **Exactly one note.**
5. Write notes, then discard from the back arrow's dialog, then reopen. **The score is back to how it opened** — and
   this is the case that could not work at all before SP5.
6. Import a `.musicxml` score, edit it, leave, reopen from the library. **A Snackbar said the edits go to a `.mscz`
   copy**, the library row now opens the `.mscz`, and the edits are in it.
7. Read the `[EditorSave] flush took …` lines. Report the largest.

- [ ] **Step 5: Judge the number**

Under ~120 ms on a real score is fine — it is one frame budget's worth of jank 2 s after the user stopped typing, and
every other op in this design already relayouts the whole score on the same thread. If it is materially worse than
that on a large score, say so and stop rather than absorbing it silently: moving the encode off the main thread is a
concurrency change to `EditorBridge`, which is out of this plan's scope and is the user's call.

- [ ] **Step 6: Revert the instrumentation and commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing checkout -- Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift
```

Re-apply anything from Task 4/5 that shared the file if the checkout took it — check `git diff` before and after, and
prefer editing the `print` lines out by hand if the file has uncommitted work.

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Scripts/android-build-editor-libs.sh
```

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "chore(android): rebuild the editor .so without the save timing log"
```

- [ ] **Step 7: Update the project memory**

`~/.claude/projects/-Users-kiichi-Developer-Personal-ios-apps-Folino-iOS/memory/project_android_note_editing.md`
opens with "最大の残件は SP5（Android は編集を 1 バイトも保存していない）" and carries a whole section headed
"⚠ Android の音符編集は「保存」を実装していない（最大の残件 = SP5）". Both are false once this plan lands. Rewrite
that section to record what SP5 actually built (the two-column partial refresh and why it is two, the main-thread
debounce and the measured cost, the discard write-back), update the `description:` front-matter line, and update the
`MEMORY.md` hook. Leave the remaining open items (preview 音の可聴確認 → feel パス → merge) intact.

---

## What SP5 deliberately does not do

State these when reporting, so they are on the table before any release absorbs this work:

- **No originals store, so no revert-to-original.** The parity marker stays, reworded (Task 4 Step 3). It needs Room
  columns and a migration on a shipped schema — its own piece of work.
- **No `size_bytes` column.** Android's library does not store or show a file size; iOS's third save-derived field has
  no landing place here (Task 1 Step 10 writes that decision down where the next person will find it).
- **The encode runs on the main thread.** Deliberate, because `EditorBridge` is single-threaded by construction;
  Task 7 measures it rather than assuming it is fine.
- **A save failure is silent.** §8.4's contract — `isDirty` stays true and the next tick or the close-flush retries —
  with no user-facing error, matching iOS. Note that Android's close-flush is the last retry there is: if it also
  fails, the edits are gone with no notice. That is iOS's behaviour too, and changing it is a product decision.

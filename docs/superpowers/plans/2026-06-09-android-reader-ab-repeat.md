# Android Reader AB Repeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the iOS Reader's 3-mode repeat (Off / Repeat one / A–B Loop) to the Android Reader at full parity — global sticky mode, per-score persisted A–B range, current-measure-snapping A/B buttons, and a loop-region highlight.

**Architecture:** The `swift-sheet-music` Android engine already has the loop primitives (`setLoop`, `clearLoop`, `loopRange` StateFlow, `nativeLoopHighlightRects`, the `LoopHighlightOverlay` Compose component). The only engine gap is resolving a measure range to ticks that handles the last measure / full score — added as two thin Kotlin methods on `AndroidPlaybackEngine` (no new JNI). Everything else lives in the Folino Android app: a `RepeatMode` enum, a `ReaderRepeatController` mirroring iOS `RepeatModel` behavior, DataStore (global mode) + Room (per-score A–B range) persistence, a menu-style picker in the playback inspector + Settings, A/B buttons in the transport, and the overlay dropped into the three layout surfaces.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), Room, DataStore, swift-sheet-music (Kotlin AAR via mavenLocal SNAPSHOT), swift-wirelet JNI.

---

## Context the implementer needs

- **Pinned ssm revision:** `2b42f14` (Folino `Package.swift`). The dev clone at
  `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music` is at exactly this commit,
  clean. All loop primitives already exist there and in the published mavenLocal SNAPSHOT AARs
  (`sheet-music-android`, `sheet-music-audio-android`, `sheet-music-compose-android`,
  version `0.0.0-SNAPSHOT`).
- **iOS reference (behavior to mirror exactly):**
  - `Packages/Features/Reader/Sources/Reader/RepeatModel.swift` — setA/setB snapping, toggle-off,
    commitPending, normalize, activeLoopRange-by-mode.
  - `Packages/Features/Reader/Sources/Reader/RepeatLoop.swift` — `normalize` (swap so A ≤ B).
  - `Packages/Infrastructure/Sources/Audio/LivePlaybackController+LoopBounds.swift` — measure → loop
    bounds (the semantics `setLoopMeasures` mirrors).
- **Loop semantics (from `AndroidPlaybackEngine.setLoop`):** half-open `[startTick, endTick)`;
  playback wraps at `endTick`. So "loop through end of measure b inclusive" = end at the onset tick
  of measure `b + 1` (or the score's total tick if `b` is the last measure).
- **Current measure:** `ReaderAudioViewModel.currentCursor: StateFlow<ScoreCursor?>` is the live
  playhead. Every cursor variant carries a measure index: `ScoreCursor.Beat.measureIndex`, and
  `ScoreItemID.Note/Rest/Tuplet/Clef` → `NoteID/RestID/TupletID/ClefAnchor.measureIndex`.
- **Score identity:** `ReaderScreen(scoreId: String, …)`. The same id keys the Room `score_records`
  table. Use it to key the per-score A–B range.
- **Persistence wiring pattern:** `MainActivity.kt` (~line 405-455) loads global prefs from
  `SettingsPrefs` and passes value + `onChange` callbacks into `ReaderScreen` (see the
  `displayOptions` / `onDisplayOptionsChange` round-trip). AB-range and repeat-mode follow this
  pattern.
- **Android build toolchain (fresh worktree):** see memory
  `project_android_build_toolchain` + `project_android_reader_seekbar_toggle`. A fresh worktree
  must copy `java-generated` + `jniLibs` from the primary checkout, run `swift package resolve`,
  then gradle codegen → build (the `generateWirelet*` codegen tasks cannot be skipped with `-x`).
- **Android verification rule:** every Android change ends with `installDebug` + `adb shell` launch
  on the Pixel, then manual gesture check (memory `feedback_android_install_launch`).

## File Structure

**swift-sheet-music (ssm worktree — Phase A only):**
- Modify: `Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` — add `setLoopMeasures`, `setLoopFullScore`.
- Test: `Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineLoopMeasuresTest.kt` (new).

**Folino Android app:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/RepeatMode.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/AbRepeatRange.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderRepeatController.kt`
- Create: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderRepeatControllerTest.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/RepeatModePicker.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/AbEndpointButtons.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt` — own the repeat controller, expose mode/abRange, wire engine.
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` — picker host, A/B buttons in transport, overlay in 3 surfaces, new params.
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt` — add the repeat-mode row.
- Modify: `Android/FolinoReaderAndroid/src/main/res/values{,-ja,-ko,-zh-rCN,-zh-rTW}/strings.xml` — repeat strings.
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — `ReaderAbRepeatEntity` + DAO + v2 migration + load/save methods.
- Create: `Android/FolinoLibraryAndroid/src/test/kotlin/com/keynumber/folino/library/ReaderAbRepeatMigrationTest.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt` — `repeatMode` key/flow/setter.
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — load/save mode + AB range, pass into `ReaderScreen`.
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt` — Settings repeat picker row.

---

## Phase 0: Worktree Android build environment

### Task 0: Make the worktree's Android tree buildable

**Files:** none (environment setup).

- [ ] **Step 1: Copy generated bridge sources + native libs from the primary checkout**

The fresh worktree lacks the generated wirelet bindings and `.so` files (gitignored). Copy them from
the primary checkout so the first gradle build doesn't have to cross-compile Swift:

```bash
PRIMARY=/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
WT=/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-reader-ab-repeat
cp -R "$PRIMARY/Android/FolinoReaderAndroid/src/main/java-generated" "$WT/Android/FolinoReaderAndroid/src/main/java-generated"
cp -R "$PRIMARY/Android/FolinoReaderAndroid/src/main/jniLibs" "$WT/Android/FolinoReaderAndroid/src/main/jniLibs"
cp -R "$PRIMARY/Android/FolinoLibraryAndroid/src/main/jniLibs" "$WT/Android/FolinoLibraryAndroid/src/main/jniLibs"
cp -R "$PRIMARY/Android/FolinoSettingsAndroid/src/main/java-generated" "$WT/Android/FolinoSettingsAndroid/src/main/java-generated"
cp -R "$PRIMARY/Android/FolinoSettingsAndroid/src/main/jniLibs" "$WT/Android/FolinoSettingsAndroid/src/main/jniLibs"
```

(If a source dir doesn't exist for a module, skip that line — not all modules generate bindings.)

- [ ] **Step 2: Resolve SwiftPM deps for the Android-gated packages**

```bash
FOLINO_ANDROID=1 xcrun swift package resolve --package-path "$WT/Packages/Features/Library"
FOLINO_ANDROID=1 xcrun swift package resolve --package-path "$WT/Packages/Features/Settings"
```

- [ ] **Step 3: Confirm a clean baseline build before touching code**

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  "$WT/Android/gradlew" -p "$WT/Android" :app:assembleDebug --no-daemon
```

Expected: `BUILD SUCCESSFUL`. If codegen fails on missing Swift, follow
`project_android_build_toolchain` (prefix PATH with `/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin`).

- [ ] **Step 4: Commit nothing** — these are gitignored generated artifacts. Proceed.

---

## Phase A: ssm engine — measure-range loop resolution

This is the only `swift-sheet-music` change. Per memory `feedback_worktree_for_other_repos` and
`feedback_ssm_worktree_base_origin_main`, do ssm work in an ssm worktree branched from `origin/main`.

### Task A1: Add `setLoopMeasures` and `setLoopFullScore` to `AndroidPlaybackEngine`

**Files:**
- Modify: `<ssm-worktree>/Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt` (loop section, after `setLoop(from:throughEndOf:)` ~line 565)
- Test: `<ssm-worktree>/Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineLoopMeasuresTest.kt` (new)

- [ ] **Step 1: Create the ssm worktree**

```bash
SSM=/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
git -C "$SSM" fetch origin
git -C "$SSM" worktree add "$SSM/.claude/worktrees/android-ab-loop-bounds" -b android-ab-loop-bounds origin/main
```

Verify `origin/main` contains the loop primitives (it should — `2b42f14` is the pinned rev and is on main):

```bash
git -C "$SSM/.claude/worktrees/android-ab-loop-bounds" grep -l "fun setLoop(from: ScoreCursor, to: ScoreCursor)" -- '*AndroidPlaybackEngine.kt'
```

Expected: the file path prints. If the file/methods are missing, STOP — the base is older than expected; rebase the worktree onto `2b42f14`.

- [ ] **Step 2: Write the failing test**

Mirror the existing loop test style (a fake `jniBridge`). Look at how the engine's existing tests
build a fake bridge + prepared player; reuse that harness. The test asserts tick resolution including
the last-measure fallback to `totalTicks`.

```kotlin
package io.github.jiyimeta.sheetmusic.audio

import io.github.jiyimeta.sheetmusic.audio.model.LoopRange
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AndroidPlaybackEngineLoopMeasuresTest {

    // Uses the same fake-bridge + prepared-engine harness as the existing loop tests
    // (see AudioExportRangeEncoderTest / the setLoop tests for the pattern). The fake
    // resolves Beat(m, 0) -> tick = m * 480, and returns empty bytes for measures beyond
    // the score (measureCount = 4, ticks-per-measure = 480, totalTicks = 1920).

    @Test fun loopsInteriorMeasures() {
        val engine = preparedEngineWith(measureCount = 4, ticksPerMeasure = 480) // totalTicks = 1920
        engine.setLoopMeasures(fromMeasure = 1, toMeasure = 2)
        assertEquals(LoopRange(startTick = 480, endTick = 1440), engine.loopRange.value)
    }

    @Test fun lastMeasureEndsAtTotalTicks() {
        val engine = preparedEngineWith(measureCount = 4, ticksPerMeasure = 480)
        // Beat(4, 0) does not resolve (only measures 0..3 exist) -> fall back to totalTicks.
        engine.setLoopMeasures(fromMeasure = 3, toMeasure = 3)
        assertEquals(LoopRange(startTick = 1440, endTick = 1920), engine.loopRange.value)
    }

    @Test fun fullScoreLoopsZeroToTotal() {
        val engine = preparedEngineWith(measureCount = 4, ticksPerMeasure = 480)
        engine.setLoopFullScore()
        assertEquals(LoopRange(startTick = 0, endTick = 1920), engine.loopRange.value)
    }

    @Test fun noOpWhenStartDoesNotResolve() {
        val engine = preparedEngineWith(measureCount = 4, ticksPerMeasure = 480)
        engine.setLoopMeasures(fromMeasure = 9, toMeasure = 9) // start unresolved
        assertNull(engine.loopRange.value)
    }
}
```

Build the `preparedEngineWith(...)` helper in the test file by copying the existing loop test's
fake-bridge construction (a `JniBridge` whose `frameForCursor` returns a `FrameCodec`-encoded frame
with `tick = measureIndex * ticksPerMeasure` for `measureIndex < measureCount`, else empty bytes;
`timelineSummary` returns `[measureCount * ticksPerMeasure, …, …]`). If the existing tests don't
expose a reusable harness, replicate their fake inline here.

- [ ] **Step 3: Run the test, verify it fails**

```bash
WT=/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-ab-loop-bounds
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  "$WT/Android/gradlew" -p "$WT/Android" :SheetMusicAudioAndroid:testDebugUnitTest --tests "*LoopMeasures*" --no-daemon
```

Expected: FAIL — `setLoopMeasures` / `setLoopFullScore` unresolved.

- [ ] **Step 4: Implement the two methods**

Insert after `setLoop(from: ScoreCursor, throughEndOf: ScoreItemID)` (~line 565), in the `// ── Loop`
section. Uses the existing internal `jniBridge.frameForCursor`, `FrameCodec`, `_loopRange`, and the
already-tracked `totalTicks`:

```kotlin
/**
 * Loop measures [fromMeasure, toMeasure] inclusive. Resolves measure heads to ticks via the
 * timeline. The end is the onset tick of measure (toMeasure + 1); if that beat does not resolve
 * (toMeasure is the last measure) the end falls back to [totalTicks] so the final measure loops
 * through its full duration. No-op when EXPORTING, no player is prepared, the start beat does not
 * resolve, or the resolved range is empty. Mirrors Apple LivePlaybackController loop-bounds.
 */
fun setLoopMeasures(fromMeasure: Int, toMeasure: Int) {
    if (_state.value == PlaybackState.EXPORTING) return
    if (playerDriver == null) return
    val fromBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(ScoreCursor.Beat(fromMeasure, 0)))
    val fromFrame = if (fromBytes.isEmpty()) null else FrameCodec.decode(fromBytes)
    fromFrame ?: return
    val endBytes = jniBridge.frameForCursor(scoreHandle, ScoreCursorCodec.encode(ScoreCursor.Beat(toMeasure + 1, 0)))
    val endTick = if (endBytes.isEmpty()) totalTicks else FrameCodec.decode(endBytes).tick
    if (fromFrame.tick >= endTick) return
    _loopRange.value = LoopRange(startTick = fromFrame.tick, endTick = endTick)
}

/** Loop the entire prepared score `[0, totalTicks)`. No-op when EXPORTING or nothing is prepared. */
fun setLoopFullScore() {
    if (_state.value == PlaybackState.EXPORTING) return
    if (playerDriver == null || totalTicks <= 0) return
    _loopRange.value = LoopRange(startTick = 0, endTick = totalTicks)
}
```

Confirm imports: `ScoreCursor`, `ScoreCursorCodec`, `FrameCodec`, `LoopRange` are already imported in
this file (they back the existing `setLoop`). Add any that are missing.

- [ ] **Step 5: Run the test, verify it passes**

Same command as Step 3. Expected: PASS (4 tests).

- [ ] **Step 6: Commit (ssm worktree)**

```bash
git -C "$WT" add Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt Android/SheetMusicAudioAndroid/src/test/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngineLoopMeasuresTest.kt
git -C "$WT" commit -m "feat(android): measure-range + full-score loop helpers on AndroidPlaybackEngine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task A2: Verify in the example app, push, re-pin, republish AAR

Per memory `feedback_ssm_example_app_verify_before_push` + `feedback_ssm_example_verify_on_mac`:
the engine change is small and unit-tested, but loop wrap is audible — verify before pushing.

- [ ] **Step 1: Add a temporary AB-loop control to the ssm Android example app**

In the ssm worktree's `Examples/Android` app, add two buttons that call
`engine.setLoopMeasures(0, 1)` and `engine.setLoopFullScore()` plus a "clear" calling
`engine.clearLoop()`. Build + install + launch on the Pixel, play, and confirm the loop audibly
wraps at the expected measure and at score end (last-measure case).

- [ ] **Step 2: Report to the user, get approval to push**

Summarize what was verified. WAIT for approval (memory `feedback_ssm_example_app_verify_before_push`).

- [ ] **Step 3: After approval — remove the temp UI, push, merge to ssm main**

```bash
git -C "$WT" checkout -- Examples/Android   # drop the temp control
git -C "$WT" push origin android-ab-loop-bounds
```

Open/merge per the user's normal ssm flow (fast-forward into `main` if that's the convention), and
capture the merged commit SHA `<SSM_SHA>`.

- [ ] **Step 4: Re-pin Folino to `<SSM_SHA>` (iOS) and republish the mavenLocal AARs (Android)**

Update the `swift-sheet-music` `revision:` in every Folino `Package.swift` that pins it AND the
`project.yml` `packages:` entry, to `<SSM_SHA>` (memory: keep both in sync). Then rebuild + republish
the Android AARs from the ssm worktree so the Folino Android build sees the new engine methods
(follow the publish step in `project_android_build_toolchain` — the `swiftkit-core` / sheet-music
`publishToMavenLocal` recipe).

- [ ] **Step 5: Commit the Folino re-pin**

```bash
git -C "$WT_FOLINO" add Packages '*Package.swift' Android project.yml
git -C "$WT_FOLINO" commit -m "build: re-pin swift-sheet-music to <SSM_SHA> (Android AB-loop bounds)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase B: Folino data model + persistence

### Task B1: `RepeatMode` enum

**Files:** Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/RepeatMode.kt`

- [ ] **Step 1: Write the enum**

```kotlin
package com.keynumber.folino.reader

/**
 * Reader repeat mode. Mirrors iOS `Domain.RepeatMode`; [wire] equals the iOS rawValue so a
 * cross-platform preference export round-trips. Global & sticky (persisted in DataStore).
 */
enum class RepeatMode(val wire: String) {
    OFF("off"),
    LOOP_ALL("loopAll"),
    AB_LOOP("abLoop");

    companion object {
        fun fromWire(raw: String?): RepeatMode = entries.firstOrNull { it.wire == raw } ?: OFF
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/RepeatMode.kt
git commit -m "feat(android-reader): RepeatMode enum (off/loopAll/abLoop)"
```

### Task B2: `AbRepeatRange` value type

**Files:** Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/AbRepeatRange.kt`

- [ ] **Step 1: Write the type + normalize helper**

```kotlin
package com.keynumber.folino.reader

/**
 * A–B loop region, measure-granular (A snaps to a measure head, B to a measure end), inclusive of
 * both measures. Mirrors iOS `ABRepeatRange` reduced to the measure indices the engine needs.
 */
data class AbRepeatRange(val startMeasure: Int, val endMeasure: Int) {
    /** Swaps so start <= end (iOS `RepeatLoop.normalize`). */
    fun normalized(): AbRepeatRange =
        if (startMeasure <= endMeasure) this else AbRepeatRange(endMeasure, startMeasure)
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/AbRepeatRange.kt
git commit -m "feat(android-reader): AbRepeatRange value type"
```

### Task B3: DataStore global repeat-mode preference

**Files:** Modify `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt`

- [ ] **Step 1: Add the key** (in `object SettingsKeys`, after `a4ReferenceHz` ~line 45)

```kotlin
    /**
     * Global sticky repeat mode: "off" | "loopAll" | "abLoop". Shared key intent with iOS
     * `ReaderGlobalSettingsKey.repeatMode`. Default "off".
     */
    val repeatMode = stringPreferencesKey("reader.repeatMode")
```

- [ ] **Step 2: Add the flow + setter** (in `class SettingsPrefs`, near the other reader prefs)

```kotlin
    val repeatMode: Flow<String> = context.dataStore.data.map { it[SettingsKeys.repeatMode] ?: "off" }
```
```kotlin
    suspend fun setRepeatMode(v: String) = context.dataStore.edit { it[SettingsKeys.repeatMode] = v }
```

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt
git commit -m "feat(android-reader): global repeatMode DataStore preference"
```

### Task B4: Room per-score A–B range table (v1 → v2)

**Files:**
- Modify `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`
- Test `Android/FolinoLibraryAndroid/src/test/kotlin/com/keynumber/folino/library/ReaderAbRepeatMigrationTest.kt` (new)

- [ ] **Step 1: Add the entity + DAO** (next to the other entities/DAOs)

```kotlin
@Entity(tableName = "reader_ab_repeat")
data class ReaderAbRepeatEntity(
    @PrimaryKey @ColumnInfo(name = "score_id") val scoreId: String,
    @ColumnInfo(name = "start_measure") val startMeasure: Int,
    @ColumnInfo(name = "end_measure") val endMeasure: Int,
)

@Dao
interface ReaderAbRepeatDao {
    @Query("SELECT * FROM reader_ab_repeat WHERE score_id = :scoreId")
    fun load(scoreId: String): ReaderAbRepeatEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(entity: ReaderAbRepeatEntity)

    @Query("DELETE FROM reader_ab_repeat WHERE score_id = :scoreId")
    fun delete(scoreId: String)
}
```

- [ ] **Step 2: Register the entity, bump the version, add the migration**

In the `@Database(...)` annotation (~line 141): add `ReaderAbRepeatEntity::class` to `entities`, change
`version = 1` to `version = 2`. Add `abstract fun readerAbRepeatDao(): ReaderAbRepeatDao` to the
`LibraryDatabase` class. Define the additive migration and register it on the builder:

```kotlin
val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
    override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `reader_ab_repeat` (" +
                "`score_id` TEXT NOT NULL, `start_measure` INTEGER NOT NULL, " +
                "`end_measure` INTEGER NOT NULL, PRIMARY KEY(`score_id`))",
        )
    }
}
```

In the builder (`RoomLibraryStore`, ~line 171), add `.addMigrations(MIGRATION_1_2)` BEFORE
`.fallbackToDestructiveMigration()` (keep the destructive fallback as the safety net).

- [ ] **Step 3: Add load/save helpers on `RoomLibraryStore`** (concrete class; do NOT widen the
`LibraryStore` interface — keep the Swift-mirrored interface untouched)

```kotlin
    fun loadAbRepeat(scoreId: String): Pair<Int, Int>? =
        db.readerAbRepeatDao().load(scoreId)?.let { it.startMeasure to it.endMeasure }

    fun saveAbRepeat(scoreId: String, range: Pair<Int, Int>?) {
        val dao = db.readerAbRepeatDao()
        if (range == null) dao.delete(scoreId)
        else dao.upsert(ReaderAbRepeatEntity(scoreId, range.first, range.second))
    }
```

(`db` is the private field built at ~line 171. `allowMainThreadQueries()` is set, so these are safe to
call synchronously from the composition.)

- [ ] **Step 4: Write a migration test**

```kotlin
package com.keynumber.folino.library

import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertTrue

@RunWith(AndroidJUnit4::class)
class ReaderAbRepeatMigrationTest {
    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        LibraryDatabase::class.java,
        emptyList(),
        FrameworkSQLiteOpenHelperFactory(),
    )

    @Test fun migrate1To2_createsAbRepeatTable_preservingScores() {
        val name = "migration-test-ab"
        helper.createDatabase(name, 1).apply {
            execSQL(
                "INSERT INTO score_records (id, title, subtitle, composer, local_file_name, " +
                    "deleted_at, last_opened_at, is_favorite) VALUES " +
                    "('s1','T','','C','s1.mxl',0.0,0.0,0)",
            )
            close()
        }
        val db = helper.runMigrationsAndValidate(name, 2, true, MIGRATION_1_2)
        val cur = db.query("SELECT COUNT(*) FROM score_records WHERE id = 's1'")
        cur.moveToFirst(); assertTrue(cur.getInt(0) == 1); cur.close()
        // New table is queryable (no exception).
        db.query("SELECT * FROM reader_ab_repeat").close()
        db.close()
    }
}
```

If `MigrationTestHelper` / instrumentation isn't already wired for `FolinoLibraryAndroid`, and adding
it is heavyweight, downgrade this to a plain JVM `Robolectric`/unit assertion that `MIGRATION_1_2.migrate`
runs the `CREATE TABLE` against an in-memory `SupportSQLiteDatabase` without throwing. Either way the
assertion is: existing rows survive + new table exists.

- [ ] **Step 5: Run the test**

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  "$WT/Android/gradlew" -p "$WT/Android" :FolinoLibraryAndroid:testDebugUnitTest --tests "*ReaderAbRepeat*" --no-daemon
```

Expected: PASS (instrumented variants run on device via `connectedDebugAndroidTest`; if so, run that
target instead).

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt Android/FolinoLibraryAndroid/src/test
git commit -m "feat(android-reader): per-score AB-repeat Room table (v1→v2 migration)"
```

---

## Phase C: Repeat controller (behavior parity with iOS RepeatModel)

### Task C1: `ReaderRepeatController` + unit tests

**Files:**
- Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderRepeatController.kt`
- Test `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderRepeatControllerTest.kt`

The controller is engine- and persistence-agnostic: it takes plain callbacks so it is unit-testable
with no Android deps. `ReaderAudioViewModel` (Task D1) supplies the real callbacks.

- [ ] **Step 1: Write the failing tests**

```kotlin
package com.keynumber.folino.reader

import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ReaderRepeatControllerTest {

    private fun controller(
        currentMeasure: Int? = 0,
        initialMode: RepeatMode = RepeatMode.AB_LOOP,
        initialRange: AbRepeatRange? = null,
    ): Pair<ReaderRepeatController, MutableList<String>> {
        val log = mutableListOf<String>()
        val measure = MutableStateFlow(currentMeasure)
        val c = ReaderRepeatController(
            currentMeasureProvider = { measure.value },
            persistedRangeLoader = { initialRange },
            persistRange = { r -> log.add("persist:$r") },
            persistMode = { m -> log.add("mode:${m.wire}") },
            applyLoop = { range, mode -> log.add("loop:${mode.wire}:$range") },
            initialMode = initialMode,
        )
        c.setCurrentMeasureForTest(measure)
        return c to log
    }

    @Test fun setA_thenSetB_buildsNormalizedRange() {
        val (c, log) = controller(currentMeasure = 2)
        c.setA()
        c.setCurrentMeasure(5)
        c.setB()
        assertEquals(AbRepeatRange(2, 5), c.abRange.value)
        assertEquals("loop:abLoop:AbRepeatRange(startMeasure=2, endMeasure=5)", log.last())
    }

    @Test fun setB_beforeA_isIncomplete_noLoop() {
        val (c, _) = controller(currentMeasure = 3)
        c.setB()
        assertNull(c.abRange.value) // incomplete -> no committed range
    }

    @Test fun setA_swapsWhenAfterB() {
        val (c, _) = controller(currentMeasure = 5)
        c.setA(); c.setCurrentMeasure(2); c.setB()
        assertEquals(AbRepeatRange(2, 5), c.abRange.value) // normalized
    }

    @Test fun reTapSameMeasureClearsThatEndpoint() {
        val (c, _) = controller(currentMeasure = 2)
        c.setA(); c.setCurrentMeasure(5); c.setB()      // range 2..5
        c.setCurrentMeasure(2); c.setA()                // re-tap A's measure -> clear A
        assertNull(c.abRange.value)                      // range becomes incomplete
    }

    @Test fun modeOff_clearsLoop() {
        val (c, log) = controller(initialMode = RepeatMode.AB_LOOP, initialRange = AbRepeatRange(1, 2))
        c.setMode(RepeatMode.OFF)
        assertEquals("loop:off:null", log.last())
    }

    @Test fun modeLoopAll_appliesFullScore() {
        val (c, log) = controller(initialMode = RepeatMode.OFF)
        c.setMode(RepeatMode.LOOP_ALL)
        assertEquals("loop:loopAll:null", log.last()) // range null => applyLoop interprets as full score
    }
}
```

(The exact test helper shape — `setCurrentMeasureForTest` / `setCurrentMeasure` — is whatever the
controller exposes for tests; adjust to match Step 2. Keep the assertions: snapping to current measure,
toggle-clear on re-tap, normalize, mode→loop forwarding.)

- [ ] **Step 2: Run tests, verify they fail**

```bash
"$WT/Android/gradlew" -p "$WT/Android" :FolinoReaderAndroid:testDebugUnitTest --tests "*ReaderRepeatController*" --no-daemon
```

Expected: FAIL (class not defined).

- [ ] **Step 3: Implement the controller**

```kotlin
package com.keynumber.folino.reader

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Holds repeat state and mirrors iOS `RepeatModel` behavior. Engine/persistence-agnostic: callers
 * inject the current-measure source, persistence, and the loop-applier.
 *
 * - [setA]/[setB] snap to the current playback measure; re-tapping an endpoint's own measure clears it.
 * - The A–B range is committed (and persisted) only when both endpoints exist; it is normalized so
 *   start <= end.
 * - [setMode] persists the global mode and re-applies the active loop:
 *     OFF -> clear, LOOP_ALL -> full score, AB_LOOP -> the committed range (or clear if incomplete).
 *
 * @param applyLoop receives `(range, mode)`. For LOOP_ALL `range` is null and the applier loops the
 *   whole score; for AB_LOOP a non-null `range` loops those measures, null clears.
 */
class ReaderRepeatController(
    private val currentMeasureProvider: () -> Int?,
    private val persistedRangeLoader: () -> AbRepeatRange?,
    private val persistRange: (AbRepeatRange?) -> Unit,
    private val persistMode: (RepeatMode) -> Unit,
    private val applyLoop: (AbRepeatRange?, RepeatMode) -> Unit,
    initialMode: RepeatMode,
) {
    private val _mode = MutableStateFlow(initialMode)
    val mode: StateFlow<RepeatMode> = _mode.asStateFlow()

    private val _abRange = MutableStateFlow(persistedRangeLoader())
    val abRange: StateFlow<AbRepeatRange?> = _abRange.asStateFlow()

    private var pendingA: Int? = _abRange.value?.startMeasure
    private var pendingB: Int? = _abRange.value?.endMeasure

    // Test seam: lets a test drive the "current measure".
    private var measureOverride: Int? = null
    fun setCurrentMeasure(m: Int?) { measureOverride = m }
    private fun currentMeasure(): Int? = measureOverride ?: currentMeasureProvider()

    fun setA() {
        val m = currentMeasure() ?: return
        if (pendingA == m) { pendingA = null; commit(); return } // re-tap clears
        pendingA = m
        commit()
    }

    fun setB() {
        val m = currentMeasure() ?: return
        if (pendingB == m) { pendingB = null; commit(); return }
        pendingB = m
        commit()
    }

    fun setMode(mode: RepeatMode) {
        if (_mode.value == mode) return
        _mode.value = mode
        persistMode(mode)
        applyActiveLoop()
    }

    /** Re-apply the active loop (e.g. after the score finishes preparing or the range loads). */
    fun reapply() = applyActiveLoop()

    private fun commit() {
        val a = pendingA
        val b = pendingB
        val range = if (a != null && b != null) AbRepeatRange(a, b).normalized() else null
        if (range != null) { pendingA = range.startMeasure; pendingB = range.endMeasure }
        _abRange.value = range
        persistRange(range)
        applyActiveLoop()
    }

    private fun applyActiveLoop() {
        when (_mode.value) {
            RepeatMode.OFF -> applyLoop(null, RepeatMode.OFF)
            RepeatMode.LOOP_ALL -> applyLoop(null, RepeatMode.LOOP_ALL)
            RepeatMode.AB_LOOP -> applyLoop(_abRange.value, RepeatMode.AB_LOOP)
        }
    }
}
```

(Drop the `setCurrentMeasureForTest` reference in the test if you keep only `setCurrentMeasure`; align
the test to the actual seam.)

- [ ] **Step 4: Run tests, verify they pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderRepeatController.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderRepeatControllerTest.kt
git commit -m "feat(android-reader): ReaderRepeatController mirroring iOS RepeatModel"
```

---

## Phase D: Engine wiring in the audio ViewModel

### Task D1: Own the controller in `ReaderAudioViewModel`, derive current measure, apply loops

**Files:** Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

- [ ] **Step 1: Add a cursor → measure-index helper** (top-level in the file or a `ScoreCursor` ext)

```kotlin
/** Current measure index of a playback cursor, or null. Every variant carries a measure index. */
internal fun ScoreCursor.measureIndexOrNull(): Int? = when (this) {
    is ScoreCursor.Beat -> measureIndex
    is ScoreCursor.Item -> when (val id = arg0) {
        is ScoreItemID.Note -> id.arg0.measureIndex
        is ScoreItemID.Rest -> id.arg0.measureIndex
        is ScoreItemID.Tuplet -> id.arg0.measureIndex
        is ScoreItemID.Clef -> id.arg0.measureIndex
    }
}
```

(Confirm `ClefAnchor.measureIndex` exists; if not, return null for the Clef case.)

- [ ] **Step 2: Expose repeat state + a builder for the controller**

The controller needs persistence callbacks that only the host (MainActivity) can supply (DataStore +
Room live in the app module). So `ReaderAudioViewModel` holds a nullable controller that the screen
installs once. Add:

```kotlin
    private val _repeatController = MutableStateFlow<ReaderRepeatController?>(null)
    val repeatMode: StateFlow<RepeatMode> = _repeatController
        .flatMapLatest { it?.mode ?: MutableStateFlow(RepeatMode.OFF) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, RepeatMode.OFF)
    val abRange: StateFlow<AbRepeatRange?> = _repeatController
        .flatMapLatest { it?.abRange ?: MutableStateFlow(null) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Installs the repeat controller once the host has the per-score persistence wired. [persistMode]
     * writes the global DataStore pref; [loadRange]/[persistRange] read/write the per-score Room row.
     */
    fun installRepeatController(
        initialMode: RepeatMode,
        loadRange: () -> AbRepeatRange?,
        persistRange: (AbRepeatRange?) -> Unit,
        persistMode: (RepeatMode) -> Unit,
    ) {
        _repeatController.value = ReaderRepeatController(
            currentMeasureProvider = { currentCursor.value?.measureIndexOrNull() },
            persistedRangeLoader = loadRange,
            persistRange = persistRange,
            persistMode = persistMode,
            applyLoop = ::applyLoop,
            initialMode = initialMode,
        )
    }

    fun setRepeatMode(mode: RepeatMode) { _repeatController.value?.setMode(mode) }
    fun setRepeatA() { _repeatController.value?.setA() }
    fun setRepeatB() { _repeatController.value?.setB() }

    private fun applyLoop(range: AbRepeatRange?, mode: RepeatMode) {
        val e = engine.value ?: return
        when (mode) {
            RepeatMode.OFF -> e.clearLoop()
            RepeatMode.LOOP_ALL -> e.setLoopFullScore()
            RepeatMode.AB_LOOP ->
                if (range != null) e.setLoopMeasures(range.startMeasure, range.endMeasure)
                else e.clearLoop()
        }
    }
```

Add imports: `flatMapLatest` is already imported; add `AbRepeatRange`, `RepeatMode` (same package, no
import needed).

- [ ] **Step 3: Re-apply the active loop after prepare**

The engine only accepts loop calls once a player is prepared. In `preparePlayback`, after a successful
`e.prepare(scoreHandle)`, re-apply:

```kotlin
            try {
                e.prepare(scoreHandle)
                _repeatController.value?.reapply()
            } catch (ex: Exception) {
```

- [ ] **Step 4: Build to typecheck**

```bash
"$WT/Android/gradlew" -p "$WT/Android" :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt
git commit -m "feat(android-reader): wire repeat controller to the playback engine"
```

---

## Phase E: UI

### Task E0: Repeat strings (all 5 locales)

**Files:** `Android/FolinoReaderAndroid/src/main/res/values{,-ja,-ko,-zh-rCN,-zh-rTW}/strings.xml`

- [ ] **Step 1: Add strings** — keys and the en/ja values from iOS; provide ko/zh too (match the
existing 5-locale set). Use these exact en/ja values (from the iOS `.xcstrings`):

| key | en | ja |
| --- | --- | --- |
| `reader_repeat_label` | Repeat | リピート |
| `reader_repeat_off` | Off | オフ |
| `reader_repeat_loop_all` | Repeat one | 1曲リピート |
| `reader_repeat_ab` | A–B Loop | A–B 区間リピート |
| `reader_repeat_set_a` | Set A | A点 |
| `reader_repeat_set_b` | Set B | B点 |

(For ko/zh-rCN/zh-rTW, translate consistently with the existing reader strings in those files; if the
existing convention is to leave untranslated English fallbacks for new keys until a localization pass,
follow whatever the other recent reader keys did in those files.)

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/res
git commit -m "feat(android-reader): repeat-mode + A/B strings (en/ja/ko/zh)"
```

### Task E1: `RepeatModePicker` composable + inspector row

**Files:**
- Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/RepeatModePicker.kt`
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`

- [ ] **Step 1: Write the picker** (Material `DropdownMenu`, menu-style, mirroring the iOS Menu+Picker)

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
private fun RepeatMode.icon(): ImageVector = when (this) {
    RepeatMode.OFF -> Icons.Filled.Repeat
    RepeatMode.LOOP_ALL -> Icons.Filled.RepeatOne
    RepeatMode.AB_LOOP -> Icons.Filled.Repeat // distinguished by label "A–B Loop"
}

@Composable
private fun RepeatMode.label(): String = stringResource(
    when (this) {
        RepeatMode.OFF -> R.string.reader_repeat_off
        RepeatMode.LOOP_ALL -> R.string.reader_repeat_loop_all
        RepeatMode.AB_LOOP -> R.string.reader_repeat_ab
    },
)

@Composable
fun RepeatModePicker(selected: RepeatMode, enabled: Boolean, onSelect: (RepeatMode) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val tint =
        if (enabled) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { expanded = true }, enabled = enabled) {
            Icon(selected.icon(), contentDescription = null, modifier = Modifier.size(20.dp), tint = tint)
            Text(selected.label(), color = tint)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = tint)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (mode in RepeatMode.entries) {
                DropdownMenuItem(
                    text = { Text(mode.label()) },
                    leadingIcon = { Icon(mode.icon(), contentDescription = null) },
                    onClick = { onSelect(mode); expanded = false },
                )
            }
        }
    }
}
```

(Add the `Modifier` import. The AB icon uses `Icons.Filled.Repeat`; if the iOS `repeat_a_b` asset is
desired, import it as a drawable into `FolinoReaderAndroid` res and swap — optional polish, not
required for parity of behavior.)

- [ ] **Step 2: Add the repeat row to `PlaybackInspectorSheet`'s "General" section**

In `PlaybackInspectorSheet.kt`, inside the "General" section `LazyColumn` (after the metronome / A4
rows, ~line 160-170), add a row mirroring the existing icon+label+control layout (the
`IconSliderRow` visual: leading `Icons.Default.Repeat` icon + label + trailing control). Read
`val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()` near the other `collectAsState`
calls, and `controlsEnabled` from the same prepared-state the other rows use:

```kotlin
            item {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Repeat, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        stringResource(R.string.reader_repeat_label),
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    RepeatModePicker(
                        selected = repeatMode,
                        enabled = controlsEnabled,
                        onSelect = { audioVm.setRepeatMode(it) },
                    )
                }
            }
```

(Match the actual enabled-flag name and imports already used in this file. `audioVm` is already a
parameter of `PlaybackInspectorSheet`.)

- [ ] **Step 3: Build to typecheck**

```bash
"$WT/Android/gradlew" -p "$WT/Android" :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/RepeatModePicker.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt
git commit -m "feat(android-reader): repeat-mode picker in playback inspector"
```

### Task E2: A/B endpoint buttons in the transport

**Files:**
- Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/AbEndpointButtons.kt`
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

- [ ] **Step 1: Write the A/B capsule** (two-segment, accent when unset / neutral when set — iOS
`ABEndpointPill` adapted to Material)

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * A | B capsule. Each half is accent-tinted while its endpoint is unset and neutral once set, and
 * tapping toggles (set/clear) that endpoint. Mirrors iOS ABEndpointPill.
 */
@Composable
fun AbEndpointButtons(
    aSet: Boolean,
    bSet: Boolean,
    enabled: Boolean,
    onSetA: () -> Unit,
    onSetB: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier.height(40.dp)) {
        AbHalf("A", set = aSet, enabled = enabled, onClick = onSetA, shape = RoundedCornerShape(topStart = 20.dp, bottomStart = 20.dp))
        AbHalf("B", set = bSet, enabled = enabled, onClick = onSetB, shape = RoundedCornerShape(topEnd = 20.dp, bottomEnd = 20.dp))
    }
}

@Composable
private fun AbHalf(
    label: String,
    set: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    shape: androidx.compose.ui.graphics.Shape,
) {
    val container = if (set) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.primary
    val content = if (set) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onPrimary
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = shape,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 14.dp),
        colors = ButtonDefaults.buttonColors(containerColor = container, contentColor = content),
    ) { Text(label) }
}
```

- [ ] **Step 2: Show the A/B capsule in the transport, only in AB mode**

In `ReaderScreen.kt`, the transport exists in two forms: `TransportBar` (seek bar shown) and
`PlaybackFab` (seek bar hidden). The A/B capsule must appear in BOTH when `repeatMode == AB_LOOP`.
Pass `audioVm` is already available. Collect the needed state and render:

In `TransportBar(audioVm)`, after the seek bar `ReaderSeekBar(...)` and before/within the transport
`Box`, collect:

```kotlin
    val repeatMode by audioVm.repeatMode.collectAsStateWithLifecycle()
    val abRange by audioVm.abRange.collectAsStateWithLifecycle()
    val currentCursor by audioVm.currentCursor.collectAsStateWithLifecycle()
```

and, when `repeatMode == RepeatMode.AB_LOOP`, render the capsule aligned to the trailing edge of the
transport `Box` (mirrors iOS placing the pill on the trailing edge), reusing `isPrepared` for
`enabled`. Compute the set-state from the committed range AND pending behavior — simplest correct
mapping: A is "set" if `abRange != null` (its start is committed); to reflect pending-A-only, expose
the controller's pending state if needed. For v1, drive `aSet`/`bSet` from `abRange` presence:

```kotlin
            if (repeatMode == RepeatMode.AB_LOOP) {
                AbEndpointButtons(
                    aSet = abRange != null,
                    bSet = abRange != null,
                    enabled = isPrepared,
                    onSetA = { audioVm.setRepeatA() },
                    onSetB = { audioVm.setRepeatB() },
                    modifier = Modifier.align(Alignment.BottomEnd),
                )
            }
```

In `PlaybackFab(audioVm)`, add the same conditional capsule to the FAB `Row` (left of the
jump-to-start FAB) so it's reachable in seek-bar-hidden mode too.

> NOTE on set-state fidelity: iOS lights each half independently from `pendingA`/`pendingB`. If you
> want that exact affordance, add `pendingA`/`pendingB` StateFlows to `ReaderRepeatController` and
> expose them via `ReaderAudioViewModel` (small addition); then `aSet = pendingA != null`,
> `bSet = pendingB != null`. Do this if the simpler `abRange`-presence mapping reads wrong on device.

- [ ] **Step 3: Build to typecheck**

```bash
"$WT/Android/gradlew" -p "$WT/Android" :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/AbEndpointButtons.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android-reader): A/B endpoint buttons in transport (AB mode)"
```

### Task E3: Loop-region highlight overlay in all three layout surfaces

**Files:** Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`
(and `PagedScore` if it lives in a separate file — find where `PlaybackCursorOverlay` is used in page mode).

The shared `io.github.jiyimeta.sheetmusic.compose.cursor.LoopHighlightOverlay` takes exactly
`ReaderAudioViewModel.loopRange` and the SAME transform params as `PlaybackCursorOverlay`. Drop it in
right next to every `PlaybackCursorOverlay` call site.

- [ ] **Step 1: Add the overlay in `ReadyScore` (vertical)** — directly after the existing
`PlaybackCursorOverlay(...)` block (~line 439-449), inside the same `scoreHandle?.let { handle -> }`:

```kotlin
                    LoopHighlightOverlay(
                        scoreHandle = handle,
                        loopRangeFlow = audioVm.loopRange,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset.Zero,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(vertical = with(density) { vPadPx.toDp() }),
                    )
```

Add import `import io.github.jiyimeta.sheetmusic.compose.cursor.LoopHighlightOverlay`.

- [ ] **Step 2: Add the overlay in `HorizontalScore`** — after its `PlaybackCursorOverlay(...)`
(~line 909-917), same params it passes (`pxPerMM = fitPxPerMM, scale = scale, panOffset = Offset.Zero,
modifier = Modifier.fillMaxSize()`).

- [ ] **Step 3: Add the overlay in page mode** — find `PlaybackCursorOverlay` inside `PagedScore`
(in `ReaderScreen.kt` or a sibling file) and add `LoopHighlightOverlay` alongside it with the same
transform params that the page surface passes to the cursor overlay. The loop highlight rects map per
system, so a loop spanning a page boundary will only show on the visible page — acceptable.

- [ ] **Step 4: Build to typecheck**

```bash
"$WT/Android/gradlew" -p "$WT/Android" :FolinoReaderAndroid:compileDebugKotlin --no-daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android-reader): loop-region highlight overlay (vertical/horizontal/page)"
```

### Task E4: Settings mirror

**Files:** Modify `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`

- [ ] **Step 1: Add a repeat-mode row to the Settings Reader section** mirroring how the existing
reader settings rows (e.g. the seek-bar toggle / layout mode) are built. Read the global
`prefs.repeatMode` and write via `prefs.setRepeatMode(mode.wire)`:

```kotlin
        // In the Reader settings section, near the seek-bar / layout rows:
        val repeatMode by prefs.repeatMode.collectAsState(initial = "off")
        val scope = rememberCoroutineScope()
        SettingsRow(label = stringResource(R.string.reader_repeat_label)) {
            RepeatModePicker(
                selected = RepeatMode.fromWire(repeatMode),
                enabled = true,
                onSelect = { scope.launch { prefs.setRepeatMode(it.wire) } },
            )
        }
```

(Use the actual settings-row composable and string-resource module that `SettingsScreen.kt` already
uses; the repeat strings live in the reader module's res, so reference them the same way other shared
reader strings are referenced from Settings — or duplicate the strings into the app/settings res if
that's the existing convention.)

- [ ] **Step 2: Build to typecheck**

```bash
"$WT/Android/gradlew" -p "$WT/Android" :app:compileDebugKotlin --no-daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt
git commit -m "feat(android-reader): repeat-mode picker in Settings (global default)"
```

---

## Phase F: Host wiring (MainActivity)

### Task F1: Load/save mode (DataStore) + AB range (Room), install the controller

**Files:** Modify `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Obtain a `RoomLibraryStore` handle for AB persistence**

In the reader `composable("reader/{id}/{title}")` block (~line 405), get a store instance (reuse the
app-level one if available; otherwise `remember { RoomLibraryStore(context) }`). The DB uses
`allowMainThreadQueries()`, so sync calls are fine.

- [ ] **Step 2: Read the global mode + the per-score range; pass an install callback to `ReaderScreen`**

Add params to `ReaderScreen` (Task signature change — see Step 3) and, in the reader composable,
collect the mode and build the callbacks:

```kotlin
                val repeatModeWire by prefs.repeatMode.collectAsState(initial = "off")
                val abStore = remember { com.keynumber.folino.library.RoomLibraryStore(context) }
```

Pass into `ReaderScreen`:

```kotlin
                    repeatMode = RepeatMode.fromWire(repeatModeWire),
                    onInstallRepeat = { install ->
                        install(
                            RepeatMode.fromWire(repeatModeWire),
                            { abStore.loadAbRepeat(id)?.let { AbRepeatRange(it.first, it.second) } },
                            { r -> abStore.saveAbRepeat(id, r?.let { it.startMeasure to it.endMeasure }) },
                            { m -> scope.launch { prefs.setRepeatMode(m.wire) } },
                        )
                    },
```

- [ ] **Step 3: Add the params to `ReaderScreen` and install the controller once**

In `ReaderScreen.kt`, add parameters:

```kotlin
    repeatMode: RepeatMode = RepeatMode.OFF,
    onInstallRepeat: (install: (RepeatMode, () -> AbRepeatRange?, (AbRepeatRange?) -> Unit, (RepeatMode) -> Unit) -> Unit) -> Unit = {},
```

and install the controller once the score id is known:

```kotlin
    LaunchedEffect(scoreId) {
        onInstallRepeat { initialMode, loadRange, persistRange, persistMode ->
            audioVm.installRepeatController(initialMode, loadRange, persistRange, persistMode)
        }
    }
```

> Simpler alternative if the indirection reads awkward: pass the four callbacks directly as
> `ReaderScreen` params (`initialRepeatMode`, `loadAbRange`, `persistAbRange`, `persistRepeatMode`) and
> call `audioVm.installRepeatController(...)` in a `LaunchedEffect(scoreId)`. Prefer whichever is
> cleaner; the requirement is: controller installed once per score with Room+DataStore wired.

- [ ] **Step 4: Build the whole app**

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  "$WT/Android/gradlew" -p "$WT/Android" :app:assembleDebug --no-daemon
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android-reader): wire repeat mode (DataStore) + AB range (Room) into Reader"
```

---

## Phase G: Device verification

### Task G1: Install on the Pixel and verify behavior

**Files:** none.

- [ ] **Step 1: Install + launch** (memory `feedback_android_install_launch`)

```bash
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
  "$WT/Android/gradlew" -p "$WT/Android" :app:installDebug --no-daemon
adb shell monkey -p com.keynumber.folino.debug -c android.intent.category.LAUNCHER 1
```

(Use the actual applicationId — confirm the debug suffix in the gradle config.)

- [ ] **Step 2: Manual checklist (user-driven gestures)** — report results:
  - Open a score, open the playback inspector → repeat picker shows Off / Repeat one / A–B Loop.
  - Select "Repeat one" → play → loops the whole score at the end.
  - Select "A–B Loop" → A/B buttons appear in the transport (both seek-bar-on and seek-bar-off modes).
  - Play, tap A at measure m, tap B at a later measure → playback wraps A→B; amber band highlights
    measures m..n.
  - Set B on the LAST measure → loop runs to the end of the score (the `setLoopFullScore`/`totalTicks`
    fallback path) and wraps.
  - Re-tap A on its own measure → A clears (loop stops being applied).
  - Mode persists across app restart; the A–B range persists across closing and reopening the SAME
    score (Room), and is independent per score.
  - Settings → Reader → repeat picker mirrors and sets the global default.
  - Cross-check the overlay alignment in all three layout modes (vertical / horizontal / page).

- [ ] **Step 3: Report to the user** — do NOT merge. Per project convention the user runs the final
clean build + does the gesture sign-off. Summarize what was verified on-device and what remains for
the user.

---

## Self-Review

- **Spec coverage:** 3-mode picker (E1, E4) ✓; current-measure-snap A/B (C1, E2) ✓; global mode in
  DataStore (B3) ✓; per-score AB range in Room with migration (B4) ✓; loop overlay (E3) ✓; engine
  wiring incl. last-measure/full-score (A1, D1) ✓; Settings mirror (E4) ✓; strings (E0) ✓; out-of-scope
  playlist continuation untouched ✓.
- **Open risks resolved:** risk #1 (last-measure end tick) is handled by `setLoopMeasures`'
  `totalTicks` fallback (A1), confirmed against the engine's no-op-on-unresolved-`to` behavior. risk #2
  (score identity) resolved — `scoreId` keys both `score_records` and the new `reader_ab_repeat`. risk
  #3 (overlay transform per layout mode) handled by reusing each surface's existing
  `PlaybackCursorOverlay` transform params (E3).
- **Type consistency:** `RepeatMode` (.OFF/.LOOP_ALL/.AB_LOOP, `.wire`, `.fromWire`), `AbRepeatRange`
  (`startMeasure`/`endMeasure`/`normalized()`), `ReaderRepeatController` (`setA/setB/setMode/reapply`,
  `mode`/`abRange`), `ReaderAudioViewModel` (`installRepeatController`, `setRepeatMode/A/B`,
  `repeatMode`/`abRange`/`loopRange`), engine (`setLoopMeasures`/`setLoopFullScore`/`clearLoop`) — used
  consistently across tasks.
- **Note:** A few UI tasks (E1/E2/E4) reference "match the existing row/enabled-flag/string-reference
  convention in this file" rather than inlining every surrounding line, because those files were not
  read line-by-line. The implementer should open the cited file region first and follow the local
  pattern. The behavior and composable contracts are fully specified.

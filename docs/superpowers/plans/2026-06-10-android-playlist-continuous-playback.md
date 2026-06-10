# Android Playlist Continuous Playback / Repeat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make playlist continuous playback function on Android — when a score opened from a playlist finishes, auto-advance to the next score (or loop), matching iOS behavior exactly.

**Architecture:** The advance decision stays in shared Swift (`Domain.PlaylistPlaybackProgression`), reached from Kotlin via a new `FolinoReaderJNI` jextract bridge — no Kotlin port. End-of-score is detected in `ReaderAudioViewModel` by mirroring iOS's "cursor → null while loaded" predicate. Advance is an **in-place `scoreId` retarget** (the Reader already keys all per-score effects on `scoreId` and keeps its view models alive), structurally identical to iOS `ReaderViewModel.advance(to:)` — no navigation event, no engine re-bind. A minimal, merge-friendly continuation picker lands in the playback inspector.

**Tech Stack:** Swift 6.3 (Domain + FolinoReaderJNI via swift-java/jextract), Kotlin + Jetpack Compose, Room, DataStore, Gradle.

**Spec:** `docs/superpowers/specs/2026-06-10-android-playlist-continuous-playback-design.md` (and its parent iOS spec `2026-06-09-playlist-continuous-playback-design.md`).

**Key facts the implementer needs:**
- Domain enums are `RawValue == String`: `RepeatMode` → `"off" | "loopAll" | "abLoop"`; `PlaylistContinuationMode` → `"off" | "playThrough" | "loopPlaylist"`.
- The existing JNI bridge precedent is `nativeScrollOffsetKeepingInView` in `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift`; jextract auto-exports every `public` function in that target.
- Android per-score wiring lives in `MainActivity.kt`'s `reader/{id}/{title}` composable (lines ~476–630), keyed by the nav-arg `id`.
- `ReaderScreen` per-score effects are already keyed on `scoreId` / `scoreHandle` (`ReaderScreen.kt:182–207`); `readerVm` / `audioVm` are `viewModel()`-scoped to the nav entry and persist across a `scoreId` change.
- DataStore continuation pref already exists: `SettingsPrefs.playlistContinuationMode` (default `"playThrough"`) + `setPlaylistContinuationMode(String)`.
- `RoomLibraryStore.loadAll(): List<ScoreRecordWire>` (each has `deletedAt: Double`) and `loadPlaylistItems(): List<PlaylistItemWire>` (`playlistId`, `scoreItemId`, `position`) already exist.

**Android build/test commands (used by several tasks):**
- Rebuild Reader JNI `.so` + regenerate Java bindings: `Scripts/android-build-reader-libs.sh` (self-sets `TOOLCHAINS` + `FOLINO_ANDROID=1`).
- Kotlin unit tests: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest`
- Install on emulator: `Android/gradlew -p Android :app:installDebug`
- Launch: `adb shell monkey -p com.keynumber.folino -c android.intent.category.LAUNCHER 1`
- Per the project's Android rule, after any Android change finish with installDebug + launch on the emulator (`emulator-5554`); never disconnect a physical Pixel.

---

## Task 1: Shared wire decision function (Domain) + test

Keep the rawValue parsing and the `Advance → Int` encoding in shared Domain so both the decision **and its wire mapping** are unit-tested on iOS; the JNI wrapper (Task 2) becomes a pure delegation.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Presentation/PlaylistPlaybackProgression.swift`
- Test: `Packages/Domain/Tests/DomainTests/PlaylistPlaybackProgressionTests.swift`

- [ ] **Step 1: Write the failing test** — append inside the `PlaylistPlaybackProgressionTests` struct (after the existing tests, before the closing `}`):

```swift
    @Test
    func `wire form: stop maps to -1, advance maps to the index`() {
        // playThrough: middle advances, last stops
        #expect(P.nextActionWire(currentIndex: 0, count: 3, repeatModeRawValue: "off", continuationRawValue: "playThrough") == 1)
        #expect(P.nextActionWire(currentIndex: 2, count: 3, repeatModeRawValue: "off", continuationRawValue: "playThrough") == -1)
        // loopPlaylist: last wraps to 0
        #expect(P.nextActionWire(currentIndex: 2, count: 3, repeatModeRawValue: "off", continuationRawValue: "loopPlaylist") == 0)
        // repeat active always stops
        #expect(P.nextActionWire(currentIndex: 0, count: 3, repeatModeRawValue: "loopAll", continuationRawValue: "loopPlaylist") == -1)
        // unknown raw values fall back to .off → stop
        #expect(P.nextActionWire(currentIndex: 0, count: 3, repeatModeRawValue: "??", continuationRawValue: "??") == -1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Packages/Domain/`): `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/PlaylistPlaybackProgressionTests`
Expected: FAIL — `nextActionWire` is not a member of `PlaylistPlaybackProgression`.

- [ ] **Step 3: Add the wire function** — append to `PlaylistPlaybackProgression.swift`, after the closing `}` of the `enum PlaylistPlaybackProgression`:

```swift

public extension PlaylistPlaybackProgression {
    /// Wire-friendly form of `nextAction` for the Android JNI bridge: the enums cross as their
    /// `rawValue` strings and the `Advance` result collapses to an `Int` — `-1` for `.stop`, or a
    /// value `>= 0` for `.advance(toIndex:)`. Keeping the rawValue parsing and the result encoding in
    /// shared Domain means both the decision and its wire mapping are unit-tested here on iOS, and the
    /// Android jextract wrapper is a pure delegation (parity — no divergent Kotlin port).
    static func nextActionWire(
        currentIndex: Int,
        count: Int,
        repeatModeRawValue: String,
        continuationRawValue: String,
    ) -> Int {
        let repeatMode = RepeatMode(rawValue: repeatModeRawValue) ?? .off
        let continuation = PlaylistContinuationMode(rawValue: continuationRawValue) ?? .off
        switch nextAction(
            currentIndex: currentIndex, count: count,
            repeatMode: repeatMode, continuation: continuation,
        ) {
        case .stop: return -1
        case let .advance(toIndex): return toIndex
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run (from `Packages/Domain/`): `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/PlaylistPlaybackProgressionTests`
Expected: PASS (all tests in the suite green).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Presentation/PlaylistPlaybackProgression.swift Packages/Domain/Tests/DomainTests/PlaylistPlaybackProgressionTests.swift
git commit -m "feat(domain): wire form of PlaylistPlaybackProgression.nextAction for Android JNI"
```

---

## Task 2: JNI bridge wrapper + regenerate bindings

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift`
- Regenerated (do not hand-edit): `Android/FolinoReaderAndroid/src/main/java-generated/com/keynumber/folino/reader/swiftjava/FolinoReaderJNI.java` + `Android/FolinoReaderAndroid/src/main/jniLibs/*/libFolinoReaderJNI.so`

- [ ] **Step 1: Add the jextract entry point** — append to `JNISymbols.swift`:

```swift

/// swift-java (jextract) entry point for the Android Reader's playlist auto-advance. Pure delegation
/// to the shared `Domain.PlaylistPlaybackProgression.nextActionWire` so iOS and Android traverse
/// playlists identically from one implementation (parity — no divergent Kotlin port). Returns -1 for
/// `.stop`; a value >= 0 is the `.advance(toIndex:)` target in the live ordered playlist.
public func nativePlaylistNextAction(
    currentIndex: Int,
    count: Int,
    repeatModeRawValue: String,
    continuationRawValue: String,
) -> Int {
    PlaylistPlaybackProgression.nextActionWire(
        currentIndex: currentIndex,
        count: count,
        repeatModeRawValue: repeatModeRawValue,
        continuationRawValue: continuationRawValue,
    )
}
```

- [ ] **Step 2: Regenerate the `.so` and Java bindings**

Run: `Scripts/android-build-reader-libs.sh`
Expected: builds `libFolinoReaderJNI.so` for each ABI and stages it + the regenerated `FolinoReaderJNI.java`. Ends with `Done. libFolinoReaderJNI.so + libSwiftJava.so + runtime staged under: …`.

- [ ] **Step 3: Verify the generated binding exists**

Run: `grep -n "nativePlaylistNextAction" Android/FolinoReaderAndroid/src/main/java-generated/com/keynumber/folino/reader/swiftjava/FolinoReaderJNI.java`
Expected: a `public static int nativePlaylistNextAction(int currentIndex, int count, java.lang.String repeatModeRawValue, java.lang.String continuationRawValue)` line (plus the private `$nativePlaylistNextAction` native stub).

- [ ] **Step 4: Commit** (includes the regenerated artifacts)

```bash
git add Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift Android/FolinoReaderAndroid/src/main/java-generated Android/FolinoReaderAndroid/src/main/jniLibs
git commit -m "feat(android): JNI bridge nativePlaylistNextAction → shared Domain decision"
```

---

## Task 3: Kotlin `PlaylistContinuationMode` wire enum + test

A wire/UI enum only (mirrors the existing `RepeatMode.kt`); it carries the string across the bridge and drives the picker. **No decision logic.**

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaylistContinuationMode.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PlaylistContinuationModeTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaylistContinuationModeTest {
    @Test fun wire_roundTrips_eachCase() {
        for (mode in PlaylistContinuationMode.entries) {
            assertEquals(mode, PlaylistContinuationMode.fromWire(mode.wire))
        }
    }

    @Test fun wire_values_matchIosRawValues() {
        assertEquals("off", PlaylistContinuationMode.OFF.wire)
        assertEquals("playThrough", PlaylistContinuationMode.PLAY_THROUGH.wire)
        assertEquals("loopPlaylist", PlaylistContinuationMode.LOOP_PLAYLIST.wire)
    }

    @Test fun fromWire_unknown_defaultsToPlayThrough() {
        assertEquals(PlaylistContinuationMode.PLAY_THROUGH, PlaylistContinuationMode.fromWire(null))
        assertEquals(PlaylistContinuationMode.PLAY_THROUGH, PlaylistContinuationMode.fromWire("bogus"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.PlaylistContinuationModeTest"`
Expected: FAIL — `PlaylistContinuationMode` is unresolved.

- [ ] **Step 3: Create the enum**

```kotlin
package com.keynumber.folino.reader

/**
 * Playlist continuation mode. Mirrors iOS `Domain.PlaylistContinuationMode`; [wire] equals the iOS
 * rawValue so the value round-trips across the JNI bridge (`FolinoReaderJNI.nativePlaylistNextAction`)
 * and the cross-platform DataStore export. This is a wire/UI enum only — the advance decision lives in
 * shared Swift (`PlaylistPlaybackProgression`), never re-implemented here.
 *
 * The unknown/`null` fallback is [PLAY_THROUGH], matching the iOS default and the DataStore default.
 */
enum class PlaylistContinuationMode(val wire: String) {
    OFF("off"),
    PLAY_THROUGH("playThrough"),
    LOOP_PLAYLIST("loopPlaylist");

    companion object {
        fun fromWire(raw: String?): PlaylistContinuationMode =
            entries.firstOrNull { it.wire == raw } ?: PLAY_THROUGH
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.PlaylistContinuationModeTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaylistContinuationMode.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PlaylistContinuationModeTest.kt
git commit -m "feat(android): PlaylistContinuationMode wire/UI enum mirroring iOS"
```

---

## Task 4: Live-ordered playlist queue helper (Library) + test

A pure helper for the queue the advance handler consults: a playlist's `scoreItemId`s in `position` order, filtered to still-live (non-soft-deleted) scores — the parity of iOS `orderedLiveIDs()`.

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`
- Modify (if `testImplementation(junit)` is absent): `Android/FolinoLibraryAndroid/build.gradle.kts`
- Test: `Android/FolinoLibraryAndroid/src/test/kotlin/com/keynumber/folino/library/PlaylistQueueTest.kt`

- [ ] **Step 1: Ensure the module has a JUnit test dependency**

Run: `grep -n "testImplementation" Android/FolinoLibraryAndroid/build.gradle.kts`
If there is no `testImplementation("junit:junit:…")` line, add inside the `dependencies { … }` block:

```kotlin
    testImplementation("junit:junit:4.13.2")
```

- [ ] **Step 2: Write the failing test**

```kotlin
package com.keynumber.folino.library

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaylistQueueTest {
    private fun item(pl: String, score: String, pos: Int) = PlaylistItemWire(pl, score, pos)
    private fun score(id: String, deletedAt: Double) =
        ScoreRecordWire(id = id, title = id, deletedAt = deletedAt)

    @Test fun ordersByPosition_filtersToRequestedPlaylist_andLiveScoresOnly() {
        val items = listOf(
            item("P1", "c", 2), item("P1", "a", 0), item("P1", "b", 1),
            item("P2", "z", 0),
        )
        val scores = listOf(
            score("a", 0.0), score("b", 12.0), score("c", 0.0), score("z", 0.0),
        )
        // "b" is soft-deleted (deletedAt != 0) → skipped; "z" belongs to P2 → excluded.
        assertEquals(listOf("a", "c"), orderedLivePlaylistScoreIds(items, scores, "P1"))
    }

    @Test fun emptyWhenPlaylistUnknown() {
        assertEquals(emptyList<String>(), orderedLivePlaylistScoreIds(emptyList(), emptyList(), "P1"))
    }
}
```

> Note: `ScoreRecordWire` may have more fields than `id` / `title` / `deletedAt`. If its constructor requires others, fill them with neutral values in the two test helpers — only `id` and `deletedAt` matter to this helper.

- [ ] **Step 3: Run test to verify it fails**

Run: `Android/gradlew -p Android :FolinoLibraryAndroid:testDebugUnitTest --tests "com.keynumber.folino.library.PlaylistQueueTest"`
Expected: FAIL — `orderedLivePlaylistScoreIds` is unresolved.

- [ ] **Step 4: Add the pure helper + an instance accessor** — in `RoomLibraryStore.kt`, add the top-level function (outside the class, e.g. at end of file):

```kotlin
/**
 * A playlist's score ids in `position` order, filtered to the requested playlist and to live scores.
 * "Live" = `deletedAt == 0.0` (the soft-delete sentinel; a non-zero `deletedAt` is a tombstone).
 * Pure so it is unit-tested without Room. Mirrors iOS `orderedLiveIDs()` — used by the Reader's
 * playlist auto-advance to skip scores deleted mid-session.
 */
internal fun orderedLivePlaylistScoreIds(
    items: List<PlaylistItemWire>,
    scores: List<ScoreRecordWire>,
    playlistId: String,
): List<String> {
    val live = scores.filter { it.deletedAt == 0.0 }.map { it.id }.toSet()
    return items.filter { it.playlistId == playlistId }
        .sortedBy { it.position }
        .map { it.scoreItemId }
        .filter { it in live }
}
```

Then add an instance method **inside the `RoomLibraryStore` class** (next to `loadPlaylistItems`), reusing the existing public reads:

```kotlin
    /** Live, position-ordered score ids for [playlistId] (or empty). Backs the Reader's auto-advance. */
    fun orderedLivePlaylistScoreIds(playlistId: String): List<String> =
        orderedLivePlaylistScoreIds(loadPlaylistItems(), loadAll(), playlistId)
```

> Verify the soft-delete sentinel: confirm `deletedAt == 0.0` is how this codebase marks a live score (check how `loadAll()`'s consumers / the Swift bridge treat `deletedAt`). If the convention differs, match it in the `live` filter — the rest of the helper is unaffected.

- [ ] **Step 5: Run test to verify it passes**

Run: `Android/gradlew -p Android :FolinoLibraryAndroid:testDebugUnitTest --tests "com.keynumber.folino.library.PlaylistQueueTest"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt Android/FolinoLibraryAndroid/src/test/kotlin/com/keynumber/folino/library/PlaylistQueueTest.kt Android/FolinoLibraryAndroid/build.gradle.kts
git commit -m "feat(android): live-ordered playlist queue helper for Reader auto-advance"
```

---

## Task 5: End-of-score detection in `ReaderAudioViewModel`

Mirror iOS `ReaderPlaybackSession.startObservingCursor()`: the engine nils the playback cursor while a score is loaded ⇒ end-of-score. `pause()` does **not** nil the cursor; `stop()` / teardown does. A `hasLoadedIntoPlayback` flag distinguishes "reached the end while loaded" from a teardown nil. This is engine-dependent and is **verified by instrumentation in Task 9**, not by a unit test.

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

- [ ] **Step 1: Add the loaded flag + the end-of-score event** — in `ReaderAudioViewModel`, near the other state declarations (e.g. after the `currentCursor` StateFlow at line ~76), add:

```kotlin
    // Mirrors iOS `ReaderPlaybackSession.hasLoadedIntoPlayback`: true once a score is prepared into the
    // engine, cleared at natural end (below) and on teardown. Distinguishes the engine's natural
    // end-of-score cursor nil from a teardown nil, so auto-advance fires only at a true end.
    @Volatile
    private var hasLoadedIntoPlayback = false

    // One-shot end-of-score signal. The Reader collects this to run the playlist auto-advance decision.
    // No replay; buffered by 1 so an emit without an active collector is not dropped.
    private val _onReachedEnd = kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val onReachedEnd: kotlinx.coroutines.flow.SharedFlow<Unit> =
        _onReachedEnd.asSharedFlow()
```

- [ ] **Step 2: Observe the cursor for the natural-end transition** — add to the end of the `init { … }` block (after `bindService`):

```kotlin
        // End-of-score = the engine nils the cursor while a score is loaded (iOS parity). The flag is
        // cleared here before emitting so a subsequent teardown/re-prepare nil cannot re-fire advance.
        viewModelScope.launch {
            currentCursor.collect { cursor ->
                if (cursor == null && hasLoadedIntoPlayback) {
                    hasLoadedIntoPlayback = false
                    _onReachedEnd.tryEmit(Unit)
                }
            }
        }
```

- [ ] **Step 3: Set the flag once a score is prepared** — in `preparePlayback`, immediately after the successful `e.prepare(scoreHandle)` call (inside the `try`, before `e.setMasterVolume(...)`):

```kotlin
                e.prepare(scoreHandle)
                hasLoadedIntoPlayback = true
```

- [ ] **Step 4: Clear the flag on teardown** — in `onCleared()`, before `unbindService`:

```kotlin
    override fun onCleared() {
        hasLoadedIntoPlayback = false
        getApplication<Application>().unbindService(connection)
        super.onCleared()
    }
```

- [ ] **Step 5: Verify it compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt
git commit -m "feat(android): end-of-score detection (cursor-nil-while-loaded) mirroring iOS"
```

---

## Task 6: Reader advance handler + in-place retarget params (`ReaderScreen`)

`ReaderScreen` collects `onReachedEnd`, asks the shared decision via JNI, and on `advance` flags auto-play and asks the host to retarget `scoreId`. The host (Task 7) maps that to an in-place `currentScoreId` change.

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

- [ ] **Step 1: Add the new parameters** — in the `ReaderScreen(...)` parameter list, alongside the existing repeat params (after `persistRepeatMode`, before `readerVm` / `audioVm`):

```kotlin
    /** Non-null only when the Reader was opened from a playlist; enables the continuation control + auto-advance. */
    playlistId: String? = null,
    /** Live, position-ordered score ids of the current playlist (re-derived each call; never a frozen snapshot). */
    playlistQueueProvider: suspend () -> List<String> = { emptyList() },
    /** The global sticky continuation mode (re-read each end-of-score so a Settings change is picked up). */
    continuationModeProvider: suspend () -> PlaylistContinuationMode = { PlaylistContinuationMode.PLAY_THROUGH },
    /** Persists the global sticky continuation mode. */
    persistContinuationMode: (PlaylistContinuationMode) -> Unit = {},
    /** Asks the host to retarget the Reader to [scoreId] in place (host sets its currentScoreId). */
    onRetargetScore: (String) -> Unit = {},
```

- [ ] **Step 2: Add the auto-play flag** — near the top of the body (after `val playbackState by audioVm.state.collectAsStateWithLifecycle()` at line ~240):

```kotlin
    // Set when this screen initiates an auto-advance; consumed once the next score reaches PREPARED.
    var pendingAutoplay by remember { mutableStateOf(false) }
```

- [ ] **Step 3: Collect end-of-score → decide → retarget** — add alongside the other `LaunchedEffect`s (after the repeat-controller install effect, ~line 193):

```kotlin
    // Playlist auto-advance: on a real end-of-score, ask the shared Domain decision (via JNI) what to
    // do next. Only active in a playlist context. Re-derives the live queue + re-reads the global
    // continuation mode each time (parity with iOS).
    LaunchedEffect(playlistId, scoreId) {
        if (playlistId == null) return@LaunchedEffect
        audioVm.onReachedEnd.collect {
            val queue = playlistQueueProvider()
            val index = queue.indexOf(scoreId)
            if (index < 0) return@collect
            val next = com.keynumber.folino.reader.swiftjava.FolinoReaderJNI.nativePlaylistNextAction(
                index,
                queue.size,
                audioVm.repeatMode.value.wire,
                continuationModeProvider().wire,
            )
            if (next in queue.indices) {
                pendingAutoplay = true
                onRetargetScore(queue[next])
            }
        }
    }
```

- [ ] **Step 4: Auto-play the advanced score once prepared** — add as its own `LaunchedEffect`:

```kotlin
    // Continuous playback implies auto-play: once the retargeted score finishes preparing, start it.
    LaunchedEffect(playbackState) {
        if (playbackState == PlaybackState.PREPARED && pendingAutoplay) {
            audioVm.engine.value?.play()
            pendingAutoplay = false
        }
    }
```

- [ ] **Step 5: Verify it compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL. (If `PlaybackState` / `mutableStateOf` imports are missing, add `import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState` and the Compose runtime imports already present in the file.)

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android): Reader playlist auto-advance handler + in-place retarget params"
```

---

## Task 7: Host wiring — in-place `currentScoreId`, route provenance, providers (`MainActivity` + `PlaylistDetailScreen`)

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Extend the reader route to carry the playlist** — change the reader `composable(...)` declaration (line ~476) to add an optional `playlistId` query arg:

```kotlin
            composable(
                "reader/{id}/{title}?playlistId={playlistId}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("title") { type = NavType.StringType },
                    navArgument("playlistId") {
                        type = NavType.StringType
                        nullable = true
                        defaultValue = null
                    },
                ),
            ) { entry ->
                val navId = entry.arguments?.getString("id") ?: ""
                val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
                val playlistId = entry.arguments?.getString("playlistId")
                // In-place retarget anchor: seeded from the nav arg, advanced by the Reader's auto-advance.
                // Keyed on navId so opening a different score from the library resets it.
                var currentScoreId by rememberSaveable(navId) { mutableStateOf(navId) }
```

- [ ] **Step 2: Base every per-score binding on `currentScoreId`** — within this composable block (the body that follows, ~lines 483–629), replace **every** use of the old `id` with `currentScoreId`. Concretely: `prefsVm` key `"readerPrefs/$id"` → `"readerPrefs/$currentScoreId"`; `LaunchedEffect(id) { prefsVm.open(id, …) }` → `LaunchedEffect(currentScoreId) { prefsVm.open(currentScoreId, …) }`; `abRepeatStore.loadAbRepeat(id)` / `saveAbRepeat(id, …)` → `currentScoreId`; `onEditInfo = { nav.navigate("editInfo/$id") }` and `onEditInfoForScore`/`editInfo/$id` → `currentScoreId`; `ReaderScreen(scoreId = id, …)` → `scoreId = currentScoreId`. (The old `id` identifier should no longer appear in this block.)

> Why: `ReaderScreen` already keys its per-score effects on `scoreId`; `readerVm`/`audioVm` persist across the change. Setting `currentScoreId` retargets the whole per-score graph in place — engine re-prepared, this score's `ReaderPreferences` reloaded — with no nav event, mirroring iOS `advance(to:)`.

- [ ] **Step 3: Pass the new Reader params** — in that same `ReaderScreen(...)` call, after the existing `persistRepeatMode = …` argument, add:

```kotlin
                    playlistId = playlistId,
                    playlistQueueProvider = {
                        playlistId?.let {
                            withContext(Dispatchers.IO) { abRepeatStore.orderedLivePlaylistScoreIds(it) }
                        } ?: emptyList()
                    },
                    continuationModeProvider = {
                        PlaylistContinuationMode.fromWire(prefs.playlistContinuationMode.first())
                    },
                    persistContinuationMode = { m ->
                        scope.launch { prefs.setPlaylistContinuationMode(m.wire) }
                    },
                    onRetargetScore = { next -> currentScoreId = next },
```

> `abRepeatStore` is the existing `RoomLibraryStore(context)` instance already constructed in this block (line ~505). Add imports if missing: `import kotlinx.coroutines.withContext`, `import kotlinx.coroutines.Dispatchers`, `import kotlinx.coroutines.flow.first`, and `import com.keynumber.folino.reader.PlaylistContinuationMode`.

- [ ] **Step 4: Make the playlist opener carry `playlistId`** — in the `playlist/{id}/{name}` composable (line ~420), replace `onOpenScore = openReader` with a playlist-aware opener (the playlist `id` is in scope there):

```kotlin
                    onOpenScore = { row ->
                        vm.markOpened(row.id)
                        val t = URLEncoder.encode(row.title, "UTF-8")
                        nav.navigate("reader/${row.id}/$t?playlistId=$id")
                    },
```

> Leave all other entry points (`list`, `recent`, `favorites`, `recentlyDeleted`, `tags`) using `openReader` (no `playlistId` → standalone, unchanged).

- [ ] **Step 5: Build the app**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): in-place Reader retarget + playlist route provenance + providers"
```

---

## Task 8: Minimal continuation picker UI (playback inspector)

Intentionally minimal and self-contained so the concurrent inspector work can restyle/relocate it without logic changes. Shown only in a playlist context; disabled when `repeatMode != OFF` (one-directional gating, repeat wins).

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaylistContinuationPicker.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values/strings.xml` (and any localized `values-*/strings.xml` present — at minimum `values-ja/strings.xml`)

- [ ] **Step 1: Add string resources** — in `Android/FolinoReaderAndroid/src/main/res/values/strings.xml`:

```xml
    <string name="reader_playlist_continuation_label">Playlist</string>
    <string name="reader_continuation_off">Off</string>
    <string name="reader_continuation_play_through">Continuous</string>
    <string name="reader_continuation_loop_playlist">Repeat all</string>
    <string name="reader_continuation_repeat_active_hint">Repeat is on, so playback stays on this score.</string>
```

And in `Android/FolinoReaderAndroid/src/main/res/values-ja/strings.xml` (create the entries; mirror the iOS copy):

```xml
    <string name="reader_playlist_continuation_label">プレイリスト</string>
    <string name="reader_continuation_off">オフ</string>
    <string name="reader_continuation_play_through">連続再生</string>
    <string name="reader_continuation_loop_playlist">全曲リピート</string>
    <string name="reader_continuation_repeat_active_hint">リピート中は次の楽譜へ進みません</string>
```

- [ ] **Step 2: Create the picker** (mirrors `RepeatModePicker.kt`'s menu shape):

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
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
import androidx.compose.ui.res.stringResource

@Composable
private fun PlaylistContinuationMode.label(): String = stringResource(
    when (this) {
        PlaylistContinuationMode.OFF -> R.string.reader_continuation_off
        PlaylistContinuationMode.PLAY_THROUGH -> R.string.reader_continuation_play_through
        PlaylistContinuationMode.LOOP_PLAYLIST -> R.string.reader_continuation_loop_playlist
    },
)

/** Minimal menu-style continuation picker (off / continuous / repeat-all). Restyleable; logic-free. */
@Composable
fun PlaylistContinuationPicker(
    selected: PlaylistContinuationMode,
    enabled: Boolean,
    onSelect: (PlaylistContinuationMode) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val tint =
        if (enabled) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { expanded = true }, enabled = enabled) {
            Text(selected.label(), color = tint)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = tint)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (mode in PlaylistContinuationMode.entries) {
                DropdownMenuItem(
                    text = { Text(mode.label()) },
                    onClick = { onSelect(mode); expanded = false },
                )
            }
        }
    }
}
```

- [ ] **Step 3: Surface it in the inspector** — `PlaybackInspectorSheet` needs the playlist context + the continuation value/setter. First add parameters to the `PlaybackInspectorSheet(...)` signature (near `audioVm`):

```kotlin
    inPlaylist: Boolean = false,
    continuationMode: PlaylistContinuationMode = PlaylistContinuationMode.PLAY_THROUGH,
    onContinuationModeChange: (PlaylistContinuationMode) -> Unit = {},
```

Then add a row immediately after the existing repeat-mode `item { … }` (which ends at line ~238), inside the same `LazyColumn`:

```kotlin
                if (inPlaylist) {
                    item {
                        Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(Icons.AutoMirrored.Filled.PlaylistPlay, contentDescription = null)
                                Text(
                                    stringResource(R.string.reader_playlist_continuation_label),
                                    Modifier.weight(1f),
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                PlaylistContinuationPicker(
                                    selected = continuationMode,
                                    enabled = controlsEnabled && repeatMode == RepeatMode.OFF,
                                    onSelect = onContinuationModeChange,
                                )
                            }
                            if (repeatMode != RepeatMode.OFF) {
                                Text(
                                    stringResource(R.string.reader_continuation_repeat_active_hint),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
```

> Add imports if missing: `androidx.compose.foundation.layout.Column`, `androidx.compose.material.icons.automirrored.filled.PlaylistPlay`. `controlsEnabled` and `repeatMode` are already in scope in this composable.

- [ ] **Step 4: Pass the values from `ReaderScreen` into the inspector** — at the `PlaybackInspectorSheet(...)` call site in `ReaderScreen.kt` (line ~379), thread the continuation state. Add a collected continuation StateFlow near the top of `ReaderScreen` body:

```kotlin
    // Global continuation mode for the inspector control (playlist context only). Mirrors the value the
    // auto-advance handler reads; updates write through to DataStore via persistContinuationMode.
    var continuationMode by remember { mutableStateOf(PlaylistContinuationMode.PLAY_THROUGH) }
    LaunchedEffect(Unit) { continuationMode = continuationModeProvider() }
```

Then in the `PlaybackInspectorSheet(...)` call, add:

```kotlin
            inPlaylist = playlistId != null,
            continuationMode = continuationMode,
            onContinuationModeChange = { m ->
                continuationMode = m
                persistContinuationMode(m)
            },
```

- [ ] **Step 5: Verify it compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaylistContinuationPicker.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/FolinoReaderAndroid/src/main/res
git commit -m "feat(android): minimal playlist continuation picker in playback inspector"
```

---

## Task 9: Build, install, and instrumented end-to-end verification

The end-of-score detection (Task 5) rests on the assumption that `AndroidPlaybackEngine` nils `currentCursor` at natural end the way the Apple engine does. This task confirms it on the emulator and validates the whole flow.

**Files:**
- Temporary instrumentation in `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt` (removed in the last step).

- [ ] **Step 1: Add temporary instrumentation** — in the `init` cursor collector and `preparePlayback`, log the transitions:

```kotlin
        viewModelScope.launch {
            currentCursor.collect { cursor ->
                android.util.Log.d("PlaylistAdvance", "cursor=${cursor != null} loaded=$hasLoadedIntoPlayback state=${state.value}")
                if (cursor == null && hasLoadedIntoPlayback) {
                    hasLoadedIntoPlayback = false
                    android.util.Log.d("PlaylistAdvance", "reachedEnd → emit")
                    _onReachedEnd.tryEmit(Unit)
                }
            }
        }
```

- [ ] **Step 2: Rebuild the JNI libs (if not already current) and install**

Run: `Scripts/android-build-reader-libs.sh`
Then: `Android/gradlew -p Android :app:installDebug`
Then: `adb shell monkey -p com.keynumber.folino -c android.intent.category.LAUNCHER 1`
Expected: app launches on `emulator-5554`.

- [ ] **Step 3: Verify natural-end detection** — start `adb logcat -s PlaylistAdvance`. Create a playlist of ≥2 short scores, open the first **from the playlist**, set repeat = Off and continuation = Continuous in the inspector, and let it play to the end.
Expected logcat: a `reachedEnd → emit` line at end-of-score, and the Reader advances to and auto-plays the next score. Confirm `reachedEnd` does **not** log when you instead **pause** mid-score, nor when you **leave** the Reader (Back).

> If `reachedEnd` never fires at natural end (the engine does not nil the cursor, or never leaves a non-null cursor), inspect the logged `state=` / `cursor=` sequence and adjust the predicate to the engine's actual completion signal. The decision logic, retarget, and UI are unaffected.

- [ ] **Step 4: Walk the behavior matrix** (playlist context, observing the same logcat):
  - `playThrough`, middle score → advances to next; at the **last** score → stops.
  - `loopPlaylist`, last score → wraps to the first and continues.
  - `repeat = loopAll` (or A–B) → the score loops; **no** advance; the continuation picker is **disabled** with the hint.
  - Single-item playlist: `playThrough` stops; `loopPlaylist` re-plays the one score.
  - Delete the next score from the playlist mid-playback, then reach end → advance skips it (or stops/wraps if none remain).
  - Open the **same score from the library** (not the playlist) → no continuation control shown; playback stops at end (standalone, unchanged).
  - After several auto-advances, press **Back** → returns to the playlist (not to a previous score).

- [ ] **Step 5: Remove the instrumentation** — revert the temporary `Log.d` lines added in Step 1 (restore the clean Task 5 collector).

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt
git commit -m "chore(android): remove playlist auto-advance instrumentation after verification"
```

---

## Notes for the executor

- **Parity is the point:** the advance decision is shared Swift reached via JNI (Tasks 1–2). Do **not** reimplement the ladder/wrap rules in Kotlin. The Kotlin `PlaylistContinuationMode` (Task 3) is a wire/UI enum only.
- **Inspector UI is intentionally minimal (Task 8)** — another session is extending the inspector concurrently. Keep the control self-contained and default-Material so it composites cleanly later. The Settings-sheet copy of the control is out of scope (the value is already persisted in DataStore).
- **Soft-delete sentinel (Task 4):** confirm `deletedAt == 0.0` is this codebase's live marker before relying on it.
- **The load-bearing risk is Task 9 Step 3** (engine cursor-nil semantics). Treat it as a gate: if it fails, fix the predicate there, not elsewhere.

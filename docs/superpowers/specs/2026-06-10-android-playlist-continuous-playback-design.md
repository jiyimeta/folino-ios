# Android Playlist Continuous Playback / Repeat — Design

**Date:** 2026-06-10
**Status:** Approved (design) — ready for implementation plan
**Scope:** Android only. Follows the approved iOS design at logic parity.
**Parent spec:** [`2026-06-09-playlist-continuous-playback-design.md`](2026-06-09-playlist-continuous-playback-design.md) (iOS, shipped). Read it first — the *model* (priority ladder, three modes, repeat-wins precedence, global sticky enum, edge cases) is fixed there and is not re-litigated here. This document covers only the **Android-specific plumbing** needed to reach behavioral parity.

## Goal

Make playlist continuous playback **actually function** on Android, matching iOS behavior exactly:

- Open a score *from a playlist* and play it → at end-of-score, optionally advance to the next score (auto-play), with the same priority ladder as iOS.
- `PlaylistContinuationMode { off | playThrough | loopPlaylist }`, default `playThrough`, global sticky.
- Per-score `RepeatMode { off | loopAll | abLoop }` **always wins** — when repeat is active, no advance, and the continuation control is disabled.

## Current Android state (what exists, what's missing)

**Already present (no rework):**

- Per-score `RepeatMode` (`Android/FolinoReaderAndroid/.../reader/RepeatMode.kt`) with wire values matching iOS. The `RepeatModePicker` is already shown in `PlaybackInspectorSheet.kt`; A–B loop and `loopAll` already drive the engine via `ReaderRepeatController` / `ReaderAudioViewModel.applyLoop`.
- The continuation value is **persisted only**: `SettingsPrefs` stores `playlistContinuationMode` ("off" | "playThrough" | "loopPlaylist") in DataStore. Nothing consumes it.
- Playlist model in Room: `PlaylistEntity` + `PlaylistItemEntity(position)` (`FolinoLibraryAndroid/.../RoomLibraryStore.kt`).
- An existing JNI bridge precedent: `Domain.scrollOffsetKeepingInView` is surfaced to Kotlin via `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift` → generated `FolinoReaderJNI.java`, built by `Scripts/android-build-reader-libs.sh`.

**Missing (this feature):**

1. **Shared decision logic reachable from Kotlin** — `PlaylistPlaybackProgression.nextAction` (Domain, Swift) is not yet bridged to Android.
2. **End-of-score detection** — `ReaderAudioViewModel` has no "reached the end naturally" signal (iOS uses `cursor == nil` while loaded).
3. **Playlist provenance** — the Reader is opened by `reader/{id}/{title}` and does not know it came from a playlist, nor the ordered queue.
4. **Continuation UI in the Reader inspector** — only the Settings/DataStore persistence exists; the inspector control that the iOS spec requires "only when opened in a playlist context" is not built.

## Design — four parts

### 1. Decision logic: shared Swift via JNI (no Kotlin port)

Per the repo parity rule ("never reimplement iOS logic as a divergent Android code path — lift it and reuse it"), the ladder/advance/wrap decision stays in `Domain.PlaylistPlaybackProgression.nextAction` — the exact function iOS calls. Android reaches it through a thin jextract entry point, mirroring the existing scroll bridge.

Add to `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift`:

```swift
/// swift-java (jextract) entry point for the Android Reader's playlist auto-advance.
/// Pure delegation to the shared `Domain.PlaylistPlaybackProgression.nextAction` so iOS and
/// Android traverse playlists identically from one implementation (parity — no divergent Kotlin port).
/// Returns -1 for `.stop`; a value >= 0 is the `.advance(toIndex:)` target in the live ordered playlist.
public func nativePlaylistNextAction(
    currentIndex: Int,
    count: Int,
    repeatModeRawValue: String,
    continuationRawValue: String,
) -> Int {
    let repeatMode = RepeatMode(rawValue: repeatModeRawValue) ?? .off
    let continuation = PlaylistContinuationMode(rawValue: continuationRawValue) ?? .off
    switch PlaylistPlaybackProgression.nextAction(
        currentIndex: currentIndex, count: count,
        repeatMode: repeatMode, continuation: continuation,
    ) {
    case .stop: return -1
    case let .advance(toIndex): return toIndex
    }
}
```

- **Marshaling:** all primitives + `String` (the existing bridge supports these). Enums cross as their wire `rawValue` strings; the `Advance` result collapses to a single `Int` (-1 = stop, ≥0 = advance index), which fits the existing single-return pattern.
- **Regeneration:** `Scripts/android-build-reader-libs.sh` rebuilds `libFolinoReaderJNI.so` for each ABI and regenerates `FolinoReaderJNI.java`. The new method appears as `FolinoReaderJNI.nativePlaylistNextAction(int, int, String, String) -> int`.
- **No new Domain code** — `nextAction` already exists and is covered by `PlaylistPlaybackProgressionTests`.

A small Kotlin enum `PlaylistContinuationMode` (OFF / PLAY_THROUGH / LOOP_PLAYLIST, each carrying its `wire` string) is added to the Reader module, mirroring the existing `RepeatMode.kt`. This is a **wire/UI enum only** — it carries the string across the bridge and drives the picker; it contains **no decision logic**.

### 2. End-of-score detection (`ReaderAudioViewModel`)

Mirror iOS `ReaderPlaybackSession.startObservingCursor()` exactly: end-of-score = the engine nils the playback cursor while a score is loaded. `pause()` does **not** nil the cursor; `stop()` / teardown does.

- Add a `@Volatile hasLoadedIntoPlayback` flag to `ReaderAudioViewModel`: set `true` on successful prepare/play, cleared **synchronously before** any teardown/advance that will stop the engine.
- Observe `currentCursor`: when it transitions to `null` **while `hasLoadedIntoPlayback == true`**, emit a one-shot `onReachedEnd` event (a `MutableSharedFlow<Unit>` with no replay) and flip the loaded flag false.
- The screen collects `onReachedEnd` and runs the advance handler (part 3).

> ⚠️ **Primary verification risk.** This assumes `AndroidPlaybackEngine` nils `currentCursor` at natural end the way the Apple engine does (state → STOPPED, then cursor → null), and that teardown is distinguishable via the loaded flag. Both platforms use the same `swift-sheet-music` engine, so this is expected — but it must be **confirmed by instrumentation on a real device/emulator** before relying on it (log every `state` + `currentCursor` transition through one full play-to-end and one user-driven stop). If the transition differs, fall back to whatever explicit completion signal the engine exposes; the rest of the design is unaffected.

### 3. Playlist provenance + advance (in-place retarget — parity with iOS)

iOS retargets its view model in place (`ReaderViewModel.advance(to:autoPlay:)`: tears down the engine, swaps the score, reloads that score's preferences, auto-plays — all within the same mounted Reader). **Android mirrors this exactly**, because `ReaderScreen` is already structured for it: every per-score effect is keyed on `scoreId` / `scoreHandle` (`LaunchedEffect(scoreId) { readerVm.load(scoreId) }`, the repeat-controller install, `preparePlayback`), and `readerVm` / `audioVm` are `viewModel()`-scoped to the Reader nav entry, so they **persist across a `scoreId` change** — the engine binding is held, not torn down and re-bound. Changing the `scoreId` the screen renders therefore re-loads, re-prepares, and re-seeds per-score state in place, structurally identical to iOS `advance(to:)`. **No navigation event occurs on advance** (this also removes the shared-service engine re-bind race that a navigation-replacement approach would introduce).

**Driving the retarget.** In the `MainActivity` reader composable, hoist the rendered score id:

```kotlin
var currentScoreId by remember(navId) { mutableStateOf(navId) }
```

Base **all** per-score wiring on `currentScoreId` instead of the raw nav arg — the `ReaderPreferencesBridgeViewModel` key (`readerPrefs/$currentScoreId`), the Room A–B store lambdas, the seeded display/playback scalars, and `ReaderScreen(scoreId = currentScoreId, …)`. Setting `currentScoreId` retargets the whole per-score graph in place, with each score loading its own `ReaderPreferences` for free (same wiring, new key) — the iOS "each advanced score loads its own preferences" requirement, met without new code.

**Route provenance.** The Reader destination carries the originating playlist (only for the *initial* open; advance never re-navigates):

```
reader/{id}/{title}?playlistId={pid}
```

- `playlistId` present ⇒ playlist context (show the continuation control, allow auto-advance). Absent ⇒ standalone (unchanged from today; no control, no advance) — exactly the iOS "`nil` queue ⇒ standalone" rule.
- Only `PlaylistDetailScreen.onOpenScore` supplies `playlistId`; all library entry points keep opening `reader/{id}/{title}` (no query → standalone).
- Because advance is in-place (the nav entry is unchanged), **Back returns to the playlist** after any number of auto-advances — matching iOS, with no back-stack manipulation.

**Advance handler.** `ReaderScreen` collects `onReachedEnd` and (via providers owned by the app module, mirroring the existing `abRepeatStore` injection so the Reader module keeps no `:FolinoLibraryAndroid` dependency):

1. Resolves the **live ordered** score ids of `playlistId` from `RoomLibraryStore` (`playlistQueueProvider: suspend () -> List<String>`), filtering to still-extant scores — the parity of iOS `currentPlaylistQueue()` / `orderedLiveIDs()` (handles mid-session deletes; the queue is re-derived each time, never a frozen snapshot, exactly as iOS does).
2. Finds the current score's index via `indexOf(currentScoreId)`. The Room composite key `(playlist_id, score_item_id)` guarantees a score appears at most once per playlist, so the index is unambiguous (iOS passes an explicit index; uniqueness makes `indexOf` equivalent — no behavioral difference).
3. Reads the global continuation mode (`continuationModeProvider: suspend () -> PlaylistContinuationMode`, from DataStore — re-read every time, so a mid-playback change in Settings is picked up at the next boundary) and the current `repeatMode` (from `audioVm`).
4. Calls `FolinoReaderJNI.nativePlaylistNextAction(currentIndex, count, repeatMode.wire, continuation.wire)`.
5. `-1` → stop (do nothing). `>= 0` → resolve the index to its score id, set an internal `pendingAutoplay` flag, and invoke `onRetargetScore(nextId)` (which sets `currentScoreId`). After the new `scoreHandle` finishes preparing, the existing prepare effect consumes `pendingAutoplay` and calls `play()` — continuous implies auto-play, matching iOS `advance(to:autoPlay: true)`.

### 4. Inspector UI — intentionally minimal (merge-friendly)

> Another session is concurrently extending the Reader inspector. To avoid churn, this feature adds the continuation control as a **small, self-contained piece** that can be dropped in and composited later — not a redesign of the inspector.

- Add `PlaylistContinuationPicker` (mirrors the existing `RepeatModePicker` shape: a row of segmented options with `selected` / `enabled` / `onSelect`), kept in its own file in the Reader module.
- Surface it in `PlaybackInspectorSheet` **only when the Reader is in a playlist context** (`playlistId != null`). In standalone context it is not rendered.
- **Disabled when `repeatMode != OFF`**, with a short caption explaining repeat takes precedence — the one-directional gating from the iOS spec. No reverse gating.
- Bound to the global continuation value: reads `continuationModeProvider`, writes via a `persistContinuationMode` setter (DataStore). Changing it updates the global sticky default, consistent with iOS.
- Copy/labels reuse the iOS wording (オフ / 連続再生 / 全曲リピート) via Android string resources. Keep styling default-Material and unobtrusive so the parallel inspector work can restyle/relocate it without logic changes.

Settings-sheet surfacing of the same value (the iOS spec's second location) is **out of scope here** — the value is already persisted in Settings/DataStore; exposing a Settings picker is deferred to the parallel inspector/settings session to avoid collision.

## Data flow

```
engine: currentCursor → null  (while hasLoadedIntoPlayback)
  → ReaderAudioViewModel emits onReachedEnd
  → ReaderScreen advance handler:
       queue = playlistQueueProvider()            // live ordered score ids
       idx   = queue.indexOf(currentScoreId)
       mode  = continuationModeProvider()          // DataStore
       rep   = audioVm.repeatMode.value
  → FolinoReaderJNI.nativePlaylistNextAction(idx, queue.size, rep.wire, mode.wire)
       → shared Domain.PlaylistPlaybackProgression.nextAction
  → -1: stop  |  i>=0: pendingAutoplay = true; onRetargetScore(queue[i])
  → MainActivity sets currentScoreId = queue[i]  (no nav event; audioVm/readerVm persist)
  → ReaderScreen re-keys on scoreId → readerVm.load + preparePlayback in place
  → prepare effect consumes pendingAutoplay → play()
```

Structurally identical to iOS `ReaderViewModel.advance(to:autoPlay: true)`: same mounted Reader, engine re-prepared in place, per-score preferences reloaded, auto-played.

## Components touched

| Layer | File | Change |
| --- | --- | --- |
| Domain (Swift) | `PlaylistPlaybackProgression.swift` | none (reused) |
| JNI (Swift) | `FolinoReaderJNI/JNISymbols.swift` | add `nativePlaylistNextAction` |
| JNI (generated) | `FolinoReaderJNI.java`, `jniLibs/*/lib*.so` | regenerate via build script |
| Reader (Kotlin) | new `PlaylistContinuationMode.kt` | wire/UI enum |
| Reader (Kotlin) | `ReaderAudioViewModel.kt` | `hasLoadedIntoPlayback` + `onReachedEnd` |
| Reader (Kotlin) | `ReaderScreen.kt` | collect `onReachedEnd`, advance handler, `pendingAutoplay`, `onRetargetScore` + new provider params |
| Reader (Kotlin) | new `PlaylistContinuationPicker.kt` + `PlaybackInspectorSheet.kt` | minimal picker, playlist-only, repeat-gated |
| App (Kotlin) | `MainActivity.kt` | `playlistId` route query arg, hoisted `currentScoreId` driving per-score wiring, `onRetargetScore`, inject `playlistQueueProvider` / `continuationModeProvider` / `persistContinuationMode` |
| App (Kotlin) | `PlaylistDetailScreen.kt` open path | pass `playlistId` into the reader route |
| Library (Kotlin) | `RoomLibraryStore.kt` | live-ordered playlist-items query (if not already exposed) |
| Resources | strings | continuation labels + repeat-precedence caption |

## Testing

- **Decision logic:** already covered by the iOS `PlaylistPlaybackProgressionTests` (Domain) — Android calls the identical function, so no duplicate logic test is needed. A thin smoke check that the JNI bridge returns the expected ints for representative inputs is sufficient.
- **End-of-score detection:** primarily **instrumented verification** on emulator/real device (log state + cursor transitions; confirm advance fires once at natural end, never on user pause/stop, never on teardown). This is the load-bearing risk and is validated by observation, per the project's "instrument when static analysis is insufficient" practice.
- **UI gating:** the continuation picker is hidden in standalone context and disabled when `repeatMode != OFF` — verified via Compose preview / manual check.
- Per Android workflow: after building, `installDebug` + launch on the emulator and walk a playlist through end-of-score (single-item, multi-item last position, mid-playlist delete) for `playThrough` and `loopPlaylist`, plus a `repeat = loopAll` no-advance check.

## Edge cases (Android specifics; semantics fixed by the iOS spec)

- **Single-item playlist:** `playThrough` stops after the one score; `loopPlaylist` re-navigates to the same score (auto-play) — acceptable, no special-casing (matches iOS).
- **Score deleted mid-session:** `playlistQueueProvider` returns only live ids; the index is recomputed each end-of-score, so a removed next-score is naturally skipped. If nothing live remains, `nextAction` stops (or wraps for `loopPlaylist`).
- **User leaves the Reader mid-playlist:** the nav entry is disposed; `readerVm`/`audioVm` clear and the engine stops normally. No background continuation. Back returns to the playlist (in-place advance never pushed onto the back stack).
- **Continuation changed mid-playback:** re-read from DataStore at each end-of-score (provider is a `suspend` read), so the new value takes effect on the next boundary — parity with iOS.
- **Double-fire guard:** the in-place retarget clears `hasLoadedIntoPlayback` before tearing the engine down for the next score's `preparePlayback`, so the teardown nil cannot re-trigger advance; the `onReachedEnd` SharedFlow has no replay. (This is the same ordering iOS relies on in `releaseEngine()`.)

## Out of scope (YAGNI / deferred)

- Settings-sheet continuation picker (value already persisted; deferred to the parallel inspector/settings session).
- Inspector visual redesign (left to the concurrent inspector work; this adds only a minimal, restyleable control).
- Transpose on advance, cross-fade/gapless, shuffle, per-playlist override, "repeat N then advance" — all rejected in the parent iOS spec.

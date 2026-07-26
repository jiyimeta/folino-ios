# Android cheap parity batch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring six small iOS Reader/Settings/Library behaviors to the Folino Android app (parity ports + two inert-toggle fixes), each as an independent Kotlin-only commit.

**Architecture:** All changes are pure Folino-Android Kotlin (Compose UI + DataStore + Room). No ssm/JNI/Swift edits, no `.so` rebuild — the four JNI modules keep their current ABI. iOS is the reference behavior; boolean gates stay Kotlin-side (no shared-Swift lift). Spec: `docs/superpowers/specs/2026-07-12-android-cheap-parity-batch-design.md`.

**Tech Stack:** Kotlin, Jetpack Compose, DataStore Preferences, Room; JUnit for unit tests.

## Global Constraints

- Package `com.harmolo.folino`; app module `Android/app`, feature modules `Android/Folino{Reader,Library,Settings}Android`.
- DataStore keys follow the existing `SettingsKeys` pattern in `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt`: a `booleanPreferencesKey("reader.<camelCase>.enabled")`, a `Flow<Boolean>` with the iOS-matching default, and a `suspend set…`. Mirror `showSeekBar` (documented as an iOS-parity key).
- User-facing brand is lowercase `folino`. New user-visible strings go in each module's `res/values*/strings.xml` for all 5 locales (en base, ja, ko, zh-rCN, zh-rTW) — mirror an existing recently-added row's localization set.
- No partial/hunk staging — stage whole files (pre-commit hook rewrites fixed files).
- Per commit: end message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Per-task verification is a **module compile check** (`:<module>:compileDebugKotlin`) + the task's unit tests. Full `:app:installDebug` + adb launch + logcat (`.so` load ok / no FATAL) is done ONCE after all tasks (see Final Verification), not per task — the Android build is expensive and no Swift changed.

---

### Task 1: Fix the inert "Keep screen awake" toggle (#6)

The `keepAwake` pref already exists end-to-end (`SettingsKeys.keepAwake` = `reader.keepScreenAwake.enabled`, default `true`; `SettingsPrefs.keepAwake` Flow + `setKeepAwake`) and is shown in Settings — but **nothing applies it**. Wire it to the window so the screen actually stays on while reading.

**Files:**
- Read first: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt` (pref exists), `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (where the Reader is hosted / where the pref Flow is already collected for the analytics snapshot), `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (Reader root composable).
- Modify: whichever of `MainActivity.kt` / `ReaderScreen.kt` owns the Reader window scope.

**Approach:** While the Reader is foreground, apply the pref. Prefer the Compose-idiomatic path: in the Reader root, `val keepAwake by prefs.keepAwake.collectAsState(...)` and add a `KeepScreenOn(keepAwake)` effect that sets `window.addFlags(FLAG_KEEP_SCREEN_ON)` when true and clears it when false, cleared on leaving the Reader (`DisposableEffect`). If ReaderScreen has no `Activity`/`Window` handle, drive it from `MainActivity` gated on "Reader is the current destination". Do NOT add a new setting — the toggle already exists.

- [ ] **Step 1:** Read the three files; confirm where the Reader window/activity is reachable and how `keepAwake` is currently collected (analytics snapshot).
- [ ] **Step 2:** Implement a `KeepScreenOn(enabled: Boolean)` composable effect (or an Activity-side flag toggle) that adds/removes `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON`, clearing on dispose. Gate it on the Reader being visible.
- [ ] **Step 3:** Wire `prefs.keepAwake` into it at the Reader root.
- [ ] **Step 4:** Compile check — Run: `:app:compileDebugKotlin` (and `:FolinoReaderAndroid:compileDebugKotlin` if edited there). Expected: BUILD SUCCESSFUL.
- [ ] **Step 5:** Commit. `fix(reader-android): apply keep-screen-awake pref via FLAG_KEEP_SCREEN_ON (was inert)`

---

### Task 2: Playback cursor 60% dim (#4)

**Files:**
- Read first: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (the `PlaybackCursorOverlay` call sites, ~lines 755 & 1551 per audit — verify), `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt` (paged call site).
- Modify: the on-screen `PlaybackCursorOverlay` call sites in `ReaderScreen.kt` and `PagedScore.kt`.

**Approach:** iOS draws the on-screen cursor at `accent.opacity(0.6)`; PiP stays opaque. **First** inspect ssm's `PlaybackCursorOverlay` signature/behavior (it's an external swift-sheet-music Compose API): if it already applies an internal alpha, STOP and drop this task (note it in the commit-less report). Otherwise pass the accent color with `alpha = 0.6f` (`MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)`) at the on-screen call sites only; leave the PiP cursor (`ReaderPipContent`) opaque.

- [ ] **Step 1:** Locate the `PlaybackCursorOverlay` call sites and inspect the ssm API for any built-in dimming.
- [ ] **Step 2:** If not already dimmed, change the on-screen `color = abAccent` args to `abAccent.copy(alpha = 0.6f)` (keep a single source constant if both sites share one). Leave PiP opaque.
- [ ] **Step 3:** Compile check — Run: `:FolinoReaderAndroid:compileDebugKotlin`. Expected: BUILD SUCCESSFUL.
- [ ] **Step 4:** Commit. `refine(reader-android): dim on-screen playback cursor to 60% opacity`

---

### Task 3: Auto-follow opt-out toggle (#1)

**Files:**
- Read first: iOS `Packages/Features/Settings/Sources/Settings/Screens/ReaderSettingsSection.swift` + `Packages/Features/Reader/Sources/Reader/...` for `readerAutoFollowEnabled` semantics (default true; off ⇒ no auto-scroll AND no recenter-on-pause).
- Modify:
  - `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt` — add key + Flow + setter.
  - `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt` — add a Reader-section toggle row.
  - `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt` — add an inspector toggle row.
  - `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` — gate the vertical + horizontal auto-scroll re-pin (audit: ~600–659 vertical, ~1386–1445 horizontal) on the flag; when off, skip re-pin during playback and do not recenter on pause.
  - `res/values*/strings.xml` (app + reader modules as needed) — 5 locales.

**Interfaces produced:** `SettingsKeys.autoFollowEnabled = booleanPreferencesKey("reader.autoFollow.enabled")`; `SettingsPrefs.autoFollow: Flow<Boolean>` (default `true`); `suspend fun setAutoFollow(v: Boolean)`. (Task 4 consumes the same wiring pattern.)

- [ ] **Step 1: Write the failing test.** In `Android/app/src/test/...` (or the reader module's test dir if the follow decision lives there), add a unit test for a pure predicate `shouldAutoFollow(enabled: Boolean, isPlaying: Boolean, userInteracting: Boolean): Boolean` — assert `shouldAutoFollow(false, true, false) == false` and `shouldAutoFollow(true, true, false) == true`. (Extract this predicate so both #1 and #3 are unit-testable.)
- [ ] **Step 2: Run test — expect FAIL** (predicate undefined).
- [ ] **Step 3:** Add the DataStore key/Flow/setter (mirror `showSeekBar`). Implement `shouldAutoFollow` (userInteracting handled fully in Task 5; here it may default false). Gate the auto-scroll collectors in `ReaderScreen.kt` on `enabled`; when off, do not re-pin on tick and do not recenter on pause.
- [ ] **Step 4: Run test — expect PASS.**
- [ ] **Step 5:** Add the Settings row + inspector row + 5-locale strings, collecting `prefs.autoFollow`.
- [ ] **Step 6:** Compile check — Run: `:app:compileDebugKotlin` + `:FolinoReaderAndroid:compileDebugKotlin`. Expected: BUILD SUCCESSFUL.
- [ ] **Step 7:** Commit. `feat(reader-android): auto-follow opt-out toggle (settings + inspector), gate auto-scroll`

---

### Task 4: Page-turn-button visibility opt-out toggle (#2)

**Files:**
- Read first: iOS `ReaderSettingsSection.swift` for `readerPageTurnButtonsVisible` (default true; gates paged tap zones, has a footer note).
- Modify:
  - `SettingsPrefs.kt` — key + Flow + setter.
  - `SettingsScreen.kt` — Reader-section toggle row (with footer/description, page-mode relevant).
  - `DisplayInspectorSheet.kt` — inspector toggle row (page mode).
  - `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt` — gate `PageTapOverlay` rendering on the flag (currently unconditional; do NOT confuse with the existing `pageTapHintDismissed` hint gate).
  - `res/values*/strings.xml` — 5 locales.

**Interfaces produced:** `SettingsKeys.pageTurnButtonsVisible = booleanPreferencesKey("reader.pageTurnButtonsVisible.enabled")`; `SettingsPrefs.pageTurnButtonsVisible: Flow<Boolean>` (default `true`); `suspend fun setPageTurnButtonsVisible(v: Boolean)`.

- [ ] **Step 1:** Add the DataStore key/Flow/setter (mirror `showSeekBar`).
- [ ] **Step 2:** Gate `PageTapOverlay` in `PagedScore.kt` on the flag — when false, do not render the tap zones (keep the hint logic independent).
- [ ] **Step 3:** Add the Settings row (with footer) + inspector row (page mode) + 5-locale strings.
- [ ] **Step 4:** Compile check — Run: `:app:compileDebugKotlin` + `:FolinoReaderAndroid:compileDebugKotlin`. Expected: BUILD SUCCESSFUL.
- [ ] **Step 5:** Commit. `feat(reader-android): page-turn-button visibility opt-out toggle; gate paged tap zones`

---

### Task 5: Suspend auto-follow on manual viewport gesture (#3)

**Files:**
- Read first: `ReaderScreen.kt` auto-scroll collectors (from Task 3) and the scroll/zoom gesture handling (`scrollState`, pinch `transformable`/`detectTransformGestures`).
- Modify: `ReaderScreen.kt` — set a transient "user interacting" flag while the user drags/pinches during playback; feed it into `shouldAutoFollow(...)` (Task 3's predicate) so re-pin is skipped while interacting; resume on next play or manual cursor set. Only relevant when auto-follow is on.

- [ ] **Step 1: Write the failing test.** Extend the Task 3 predicate test: assert `shouldAutoFollow(true, true, userInteracting = true) == false` and `shouldAutoFollow(true, true, userInteracting = false) == true`.
- [ ] **Step 2: Run test — expect FAIL** (userInteracting not yet honored).
- [ ] **Step 3:** Honor `userInteracting` in `shouldAutoFollow`. Wire a `userInteracting` state: set true on scroll-in-progress / pinch-in-progress, reset on interaction end and on next play / manual cursor set. Ensure pinch-zoom (not just scroll) sets it (`isScrollInProgress` alone may miss pinch — see spec risk).
- [ ] **Step 4: Run test — expect PASS.**
- [ ] **Step 5:** Compile check — Run: `:FolinoReaderAndroid:compileDebugKotlin`. Expected: BUILD SUCCESSFUL.
- [ ] **Step 6:** Commit. `feat(reader-android): suspend playback auto-follow while the user pans/zooms`

---

### Task 6: Library sort order + persistence (#5)

**Files:**
- Read first: iOS `Packages/Domain/Sources/Domain/...` `ScoreItemSort` (enum was promoted to Domain — get the EXACT cases + default), iOS `Packages/Features/Library/Sources/Library/Views/ScoreSortMenu.swift` + `ScoreListViewModel.swift` (menu UX + per-list behavior + `LibrarySettingsKey.sortOrder` persistence).
- Modify:
  - `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt` — add a sort picker (menu) to the score-list surface (used by All / Favorites / Tag lists).
  - DataStore: add a `library.sortOrder` string key + Flow + setter (in `SettingsPrefs.kt` alongside the others, or a Library-scoped prefs if one exists — check first).
  - `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — apply the ordering (Room `ORDER BY` or in-memory sort of the returned list) per the selected `ScoreItemSort`.
  - `res/values*/strings.xml` — sort-option labels, 5 locales (mirror iOS `ScoreItemSort+LabelKey`).

**Interfaces produced:** a Kotlin `ScoreItemSort` enum mirroring Domain's cases 1:1 (rawValues wire-compatible if any JNI carries it — check whether sort crosses JNI or is Kotlin-only; prefer Kotlin-only if the list is materialized in Room).

- [ ] **Step 1: Read** Domain `ScoreItemSort` + iOS `ScoreSortMenu`/`ScoreListViewModel`; enumerate the exact cases, default, and whether ordering differs per list.
- [ ] **Step 2: Write the failing test.** In the Library module's test dir, add `ScoreSortTest` asserting that a fixture list of scores sorts correctly for each `ScoreItemSort` case (e.g. title A→Z, dateAdded newest-first) — match iOS semantics exactly.
- [ ] **Step 3: Run test — expect FAIL** (sort not implemented).
- [ ] **Step 4:** Add the Kotlin `ScoreItemSort` enum + the sort function; apply it in `RoomLibraryStore` (ORDER BY or post-query sort); add the `library.sortOrder` DataStore key/Flow/setter.
- [ ] **Step 5: Run test — expect PASS.**
- [ ] **Step 6:** Add the sort picker to `ScoreListScaffold.kt` + 5-locale labels; persist selection; restore on relaunch; apply to All / Favorites / Tag lists.
- [ ] **Step 7:** Compile check — Run: `:app:compileDebugKotlin` + `:FolinoLibraryAndroid:compileDebugKotlin`. Expected: BUILD SUCCESSFUL.
- [ ] **Step 8:** Commit. `feat(library-android): score-list sort picker with persisted order`

---

## Final Verification (after all tasks)

1. From the worktree, copy unchanged JNI modules' artifacts from primary to skip a full cross-compile (no Swift changed, ABIs unchanged), per `reference_android_fresh_worktree_app_build`: `cp -R <primary>/Android/<Module>/src/main/{java-generated,jniLibs}` for Settings; `jniLibs` only for Library/Soundfont; Reader too (no Swift changed here either). Confirm all four `.so`s present.
2. Build + install: `:app:installDebug` on `emulator-5554` (per `feedback_android_use_emulator_not_pixel` — never touch the physical Pixel).
3. Launch via adb; check logcat: four JNI `.so`s `load ok`, no `FATAL`.
4. Smoke each change on the emulator: keep-awake (screen stays on), cursor dim, auto-follow off (no re-pin), manual-scroll-during-play (no snap-back), page-turn toggle (tap zones gone), library sort (order changes + survives relaunch).
5. Report results; leave commits on the branch for the user (no push).

## Self-Review notes

- Spec coverage: Tasks 1–6 map 1:1 to spec items 6,4,1,2,3,5 respectively. All spec scope covered.
- `shouldAutoFollow` predicate name is used identically in Tasks 3 and 5.
- Open item carried from spec: Task 2 may be dropped if ssm already dims (documented in-task).

# Android cheap parity batch (Reader controls + Library sort + inert-toggle fixes)

**Date:** 2026-07-12
**Status:** Approved — ready for implementation plan
**Branch:** `worktree-android-parity-cheap-batch`

## Problem

A 2026-07-12 iOS→Android parity audit (code-based, see memory `project_android_ios_parity_gaps`)
found a set of small, user-facing Reader/Settings/Library behaviors that iOS ships but Android
lacks or ships non-functionally. This batch covers the six that are **pure Folino-Android Kotlin**
(no ssm/JNI/Swift change, no new `.so`): they can each land as a small independent commit. The
larger gaps (annotation, PDF import) and ssm-dependent ones (transpose effect, count-in) are out of
scope here and get their own specs later.

The guiding rule is iOS parity: iOS is the reference behavior. Where a decision is a simple boolean
gate, it stays Kotlin-side (no shared-Swift lift — the logic is too trivial to justify a JNI round
trip, unlike genuine domain logic).

## Scope — six items

### 1. Auto-follow opt-out toggle
- **iOS:** persisted `readerAutoFollowEnabled` (default `true`); rows in both the Settings Reader
  section and the Reader display inspector; gates playback auto-follow; when off, pausing does **not**
  recenter.
- **Android today:** auto-scroll is unconditional; no key, no row (`SettingsPrefs`, `SettingsScreen.kt`,
  `DisplayInspectorSheet.kt`).
- **Change:** add a DataStore key `readerAutoFollowEnabled` (default true); add a Settings Reader-section
  toggle and a display-inspector toggle; gate the vertical + horizontal auto-scroll re-pin in
  `ReaderScreen.kt` on the flag; when off, do not re-center on pause.

### 2. Page-turn-button visibility opt-out toggle
- **iOS:** persisted `readerPageTurnButtonsVisible` (default `true`); Settings row (with footer) +
  inspector row (page mode); gates the paged tap zones.
- **Android today:** `PageTapOverlay` renders unconditionally (`PagedScore.kt`); only the one-time
  onboarding hint is gated (`pageTapHintDismissed`), not the tap zones.
- **Change:** add DataStore key `readerPageTurnButtonsVisible` (default true); Settings row + inspector
  row (shown in page mode); gate `PageTapOverlay` rendering on the flag.

### 3. Suspend auto-follow on manual viewport gesture
- **iOS:** dragging / pinching / tap-turning during playback suspends auto-follow; resumes on next
  play or manual cursor set.
- **Android today:** the auto-scroll `collectLatest` re-pins on every cursor tick while playing,
  overriding a manual scroll on the next tick.
- **Change:** feed the scroll/pinch `interactionSource` (or `scrollState.isScrollInProgress` + a
  transient "user-interacting" flag) into the auto-scroll collector so it skips re-pin while the user
  is actively interacting; resume on next play / manual cursor set. Composes with #1 (only relevant
  when auto-follow is on).

### 4. Playback cursor 60% dim
- **iOS:** on-screen playback cursor uses accent color at `opacity(0.6)` on the vertical / horizontal /
  paged surfaces; PiP stays opaque.
- **Android today:** both `PlaybackCursorOverlay` call sites pass full-opacity accent.
- **Change:** pass `alpha = 0.6f` accent at the on-screen call sites (`ReaderScreen.kt`, `PagedScore.kt`);
  keep PiP opaque. First verify ssm's `PlaybackCursorOverlay` doesn't already dim internally; if it does,
  drop this item.

### 5. Library sort order (+ persistence)
- **iOS:** a `ScoreItemSort` picker on the score list; persisted (`LibrarySettingsKey.sortOrder`) and
  restored across relaunch; applies to All / Favorites / Tag lists.
- **Android today:** no sort UI at all; `RoomLibraryStore` has no score-list `ORDER BY`.
- **Change:** add a sort picker to the shared score-list surface (`ScoreListScaffold.kt`) mirroring iOS's
  `ScoreItemSort` option set **exactly** (read the iOS enum during implementation and match it 1:1);
  persist the selection to DataStore; apply the ordering (Room `ORDER BY` or in-memory sort) so All /
  Favorites / Tag lists honor it; restore on relaunch.

### 6. "Keep screen awake" toggle — fix the inert stub
- **iOS:** the "prevent auto-lock" setting (since 1.5.0) actually keeps the screen on during reading.
- **Android today:** the Settings toggle persists the pref and feeds the analytics snapshot, but
  **nothing applies it** — there is no `FLAG_KEEP_SCREEN_ON` / `keepScreenOn` / WakeLock anywhere. The
  screen still sleeps. (A shipped-looking but non-functional toggle — a bug, not just a gap.)
- **Change:** apply the existing persisted pref to the window / Reader surface via
  `FLAG_KEEP_SCREEN_ON` (or Compose `Modifier`/`keepScreenOn`) while the Reader is foreground; clear it
  when the pref is off or the Reader is left. No new setting — wire the one that already exists.

## Non-goals

- No ssm / JNI / Swift changes; no `.so` rebuild (all six are Kotlin-only). If any item turns out to
  need an engine call, it drops out of this batch and gets deferred with the ssm-dependent items.
- Transpose effect, count-in, annotation, PDF import — separate specs.
- No Android `VersionHistory.yml` re-authoring here (separate product task; must use Android's own
  version numbers, not copy iOS).

## Testing

- Follow existing Android test conventions (JUnit/Kotlin under each module's `src/test`). Add unit
  coverage for the pure logic: sort ordering (#5) and any extracted "should-follow given
  flag+interaction" predicate (#1/#3). UI-gate wiring (#2, #4, #6) is verified by the device smoke run.
- Verification per project rule: Android changes get `:app:installDebug` + adb launch + logcat check
  (four JNI `.so`s `load ok`, no `FATAL`), since these touch the running Reader/Settings/Library UI.

## Risks / open items

- **#4 double-dim:** confirm ssm's cursor overlay isn't already at 0.6 before adding alpha, or the
  cursor becomes 0.36.
- **#5 sort scope:** match the iOS `ScoreItemSort` set exactly; if iOS sorts differently per list
  (All vs Favorites vs Tag), mirror that rather than a single global order.
- **#3 gesture detection:** Compose `isScrollInProgress` may not cover pinch-zoom; ensure the pinch
  transform gesture also sets the suspend flag.
- **Fresh-worktree Android build:** unchanged JNI modules' `.so` + bindings copy from primary per
  `reference_android_fresh_worktree_app_build` (this batch changes no Swift, so ABIs are unchanged).

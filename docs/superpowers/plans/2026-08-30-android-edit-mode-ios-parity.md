# Android edit mode → iOS parity

**Date:** 2026-08-30
**Branch:** `worktree-android-edit-parity`
**Scope:** six divergences between Android's note-editing chrome and iOS's, plus the shared-code moves
that stop them coming back.

iOS is the reference for *behavior*; Android idioms still win for *placement* where the two disagree
(repo `CLAUDE.md`, "iOS / Android parity"). Every item below says which of the two it is.

---

## The six divergences

| # | Symptom on Android | iOS truth | Root cause |
| --- | --- | --- | --- |
| 1 | Playback cursor stays on screen in edit mode | The displayed cursor is dropped the moment a selection lands | iOS's rule lives in Reader glue (`onSelectionMade` → `hideDisplayedCursor`); Android never grew a counterpart |
| 2 | Nothing is selected on entering edit mode | The last tapped-to-seek item is carried into the session | iOS's carry lives in App glue + an iOS-only `EditorViewModel.selectItem`; there is no shared seam |
| 3 | ← / → steppers sit inside the pad; the transport stays full-size | Steppers are their own pill at the bottom-left; the transport drops to its compact form for the session | placement drifted independently |
| 4 | Title shown in the app bar while editing | No title | **already fixed on `main`** (`50cdb502`) — verify only |
| 5 | Back arrow shown while editing | No back affordance; ✕ discards, ✓ commits | Android kept the reading bar's navigation icon |
| 6 | A pad show/hide toggle button in the app bar | The toggle is gone; the pad tucks past a side edge, PiP-style | iOS replaced it in `6ef010a3`; Android still has the old toggle |

### What §6 looks like on each platform

Both imitate **their own OS's** PiP dismissal, so the two deliberately differ in the tucked state:

* **iOS** — the card parks entirely offscreen and leaves a `36 × 68` keyboard+chevron pull tab
  (`EditorPadTuckHandle`).
* **Android** — the card parks with a **24 dp sliver of the pad itself** still showing past the edge.
  **No new handle is added.** Dragging or tapping the sliver brings it back.

The *thresholds and release decisions* are identical and become shared code (below); only the resting
offset differs, by one `peek` parameter.

---

## Shared-code moves (the point of the exercise)

### S1 — `EditorSessionCore.selectCarriedItem(_:)`

iOS's "carry the reader's last tap into the session" guard is in `EditorViewModel+HitTest.swift`, i.e.
iOS-only. It is behavior (which carried IDs are still valid, and that carrying must *not* audition —
unlike a tap), so it moves to `EditorCore`:

```swift
/// Selects an item chosen OUTSIDE the session — the reader's last tap-to-seek — so entering edit mode
/// picks up where the finger left off. Ignores an item this score no longer contains: positional IDs
/// go stale. Never auditions: `selectFromTap` sounds because a tap asked to hear that note; opening a
/// session did not.
public func selectCarriedItem(_ item: SheetMusicCore.ScoreItemID?)
```

* iOS `EditorViewModel.selectItem(_:)` delegates to it (keeps `syncFromCore`).
* `EditorBridge` gains `@WireletExpose selectCarriedItem(frame:)` (empty bytes = nothing to carry).

### S2 — `EditorPadTuckGeometry` moves to `EditorCore`

The thresholds and release rules are exactly the kind of arithmetic that drifts into two dialects. They
move to `EditorCore`, Foundation-only (`Double`, no `CGFloat`/`CGSize` — those do not exist in the
Android Swift image), with one added parameter:

```swift
static func restOffsetX(side:viewportWidth:padWidth:margin:peek:) -> Double
```

`peek` is how much of the CARD stays on screen: **0 on iOS** (it leaves a tab instead), **24 dp on
Android**. It is the one genuinely per-platform input, so it is a parameter rather than a fork.

Unchanged and shared verbatim: `threshold` (`min(w, h) * 0.2`), `tuckDestination` (projected travel
**and** the sideways-in-substance guard), `inwardTravel`, `restoresFromTuck`.
`handleVisible` / `restorePreviewRestOffsetX` stay too — iOS uses them; Android has no handle to
preview onto, so it simply does not call them.

Exposure: a **new stateless bridge**, `EditorPadTuckBridge` (`@WireletObservable`, no stored state), so
Kotlin can call it straight from the UI thread. It must NOT hang off `EditorBridge`: that object is
confined to the single `folino-edit` executor and a gesture release would then queue behind a 200 ms
autosave. Kotlin calls it **twice per gesture** (start: threshold + rest offset; end: the release
decision) — never per frame.

*Fallback if the wirelet codegen refuses a stateless observable class:* put the same methods on
`EditorBridge` and call them off the confined executor, documenting that they touch no session state.

### Not shared, and why

* §1's `hideDisplayedCursor` is Reader-owned view state on both platforms — one line each, no seam to
  put it behind. Cross-referenced in comments instead.
* §3/§4/§5 are placement, which the parity rules explicitly keep per-platform.
* The pad's top/bottom dock is **not** ported (see the PARITY marker in Task 7).

---

## Tasks

### T1 — `EditorCore`: `selectCarriedItem` (+ tests)
`EditorSessionCore+Selection.swift`. iOS `EditorViewModel.selectItem` delegates. `EditorCoreTests`
covers: valid item selects; stale/absent slot clears; nil clears; nothing is auditioned.

### T2 — `EditorCore`: move `EditorPadTuckGeometry` (+ move its tests)
`Editor/Views/EditorPadTuck.swift` → `EditorCore/EditorPadTuckGeometry.swift`, `Double`-based, `peek`
added. `EditorPadTuckSide` moves with it; its `chevronSystemName` stays behind in the Editor module as
an extension (SwiftUI naming). iOS call sites (`EditorChromeView+Cluster.swift`,
`EditorChromeView+PadDrag.swift`) convert at the boundary and pass `peek: 0`.
`EditorTests/EditorPadTuckTests.swift` → `EditorCoreTests`, plus a case for `peek`.

### T3 — `FolinoEditorJNI`: `selectCarriedItem(frame:)` + `EditorPadTuckBridge`
Both in `Sources/FolinoEditorJNI`. Regenerate wirelet bindings, then rebuild
`libFolinoEditorJNI.so` (`Scripts/android-build-editor-libs.sh`, arm64 only for device QA) — in that
order (`reference_android_native_drift`).

### T4 — Android §1: hide the displayed cursor when a selection lands
`ReaderAudioViewModel` gains `displayCursor` (= `currentCursor`, suppressed by a flag) and
`hideDisplayedCursor()` (refused while playing, mirroring iOS). Every real cursor move clears the flag:
`handleTap`, `seek`, `play`, scrub, measure-step. `PlaybackCursorOverlay` reads `displayCursor`;
auto-scroll and PiP keep reading the real one. ReaderScreen fires the hide from a
`LaunchedEffect(editing.selectedItemFrame)` on a non-empty frame.

### T5 — Android §2: carry the last tapped item into the session
Tap-to-seek path records `ScoreItemIDCodec.encode(cursor.arg0)` when the cursor is a
`ScoreCursor.Item`, into a `ReaderViewModel`-held `lastTappedItemFrame` (cleared when the score handle
changes). `EditSessionController.begin` calls `selectCarriedItem` right after `open` succeeds, on the
same confined executor. With nothing remembered the session opens with an inert pad — iOS's behavior.

### T6 — Android §3: steppers out of the pad, compact transport
* `EditingPad`: delete `StepperKeys` and its divider; `SINGLE_ROW_KEY_COUNT` drops by 2.
* New `EditingStepperPill` composable: two `IconButton`s on a rounded `Surface`, aligned
  `BottomStart` of the reader's content Box, level with the FAB cluster, `enabled = !isPlaybackActive`
  (matching iOS: **not** gated on `hasEditTarget`).
* `showsSeekBarNow = showSeekBar && !editing.isEditing` replaces `showSeekBar` at the bottom-bar and
  FAB call sites, so editing gets Android's compact transport (the FAB cluster — already documented as
  the iOS collapsed-transport port) instead of the full `TransportBar`.

### T7 — Android §6: PiP-style side tuck replaces the toggle
* `EditUiState.isPadVisible` → `isPadExpanded` (default **true**) + `padTuckSide`.
* `EditingTopBarActions`: the `Piano` `FilledIconToggleButton` is deleted, with its string.
* The pad leaves the Scaffold `bottomBar` for a floating overlay in the content Box, aligned
  `BottomCenter` above the FAB clearance — matching iOS, where the cluster floats over the score and
  never re-engraves it. `bottomContentPad` gains the measured pad height while expanded, so the last
  system can still be scrolled clear.
* New `EditingPadTuck.kt`: the drag (horizontal only), the spring, the peek rest, tap-to-restore.
  Animation: `spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow)` — Compose's nearest
  reading of iOS's one `spring(duration: 0.4, bounce: 0.2)`.
* Persistence: `SettingsPrefs` gains `editorPadExpanded` (default true) and `editorPadTuckSide`
  (default `trailing`), wired through `MainActivity`.
* `// PARITY(android): note pad vertical dock — …` at the tuck call site: iOS also drags the pad
  between a top and a bottom dock; Android tucks sideways only.

### T8 — Android §5: ✕ instead of the back arrow while editing
`ReaderTopBar.navigationIcon` shows `Icons.Filled.Close` while `editing.isEditing` — Material's own
contextual-bar convention, and the same control iOS puts at the leading edge (`EditorDiscardButton`).
Behavior is unchanged (confirm-then-discard when there are edits). §4 (title) is verified, not changed.

### T9 — Verify
JVM unit tests (`:app`, `:FolinoReaderAndroid`, `:FolinoEditorAndroid`), the Editor instrumented
tests, iOS `Editor` + `EditorCore` tests, a device install on the Pixel, and `Scripts/parity-report.py`
via the pre-commit hook.

---

## Risks

* **`.so` rebuild.** T3 adds JNI entry points, so `libFolinoEditorJNI.so` must be rebuilt — codegen
  first, then the `.so`, or `JNI_OnLoad` comes out with mismatched signatures. If the ssm pin moves,
  `Packages/Features/Editor/.build` must be deleted first (2026-08-28's heap-corruption incident).
  It does not move here.
* **Android builds need `-PssmVersion=0.0.0-previewsupersede-SNAPSHOT`** until ssm 2.2.0 ships.
* **The pad leaving `bottomBar`** changes who reserves the space at the bottom of the score. The
  scroll padding has to move with it or the last system hides under the pad.

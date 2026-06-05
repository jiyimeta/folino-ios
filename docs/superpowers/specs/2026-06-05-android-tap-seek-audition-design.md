# Android Tap-to-Seek + Tap-Audition (iOS parity) — Design

**Date:** 2026-06-05
**Repos:** swift-sheet-music (shared logic + JNI) and Folino-iOS (iOS adoption + Android UI)
**iOS branch worktree:** `worktree-android-tap-seek-audition`

## Goal

Bring the iOS Reader's tap behavior to Android: tapping on (or near) a note **moves the playback
cursor** (seek) and, while playback is stopped/paused, **auditions that note for ~0.5 s**. Android
currently has no tap-to-seek on the score at all.

Behavior matches iOS exactly (logic parity): tap resolves to the nearest chord onset / rest on the
staff closest to the touch; seek always moves the cursor; audition fires only when not playing, only
for a `.item(.note)` result (rests are silent), single tapped note, 500 ms.

## Why this needs shared logic (not a Kotlin reimplementation)

The hit-test (`nearestCursor`) and the filtered→full-score cursor translation
(`engineCursorForFilteredTap`, needed because Android also supports hidden staves via the Display
Inspector) are non-trivial Swift that today lives only in Folino's iOS Reader. Per the iOS/Android
parity rule (logic is shared, never duplicated as a divergent path), this logic is **lifted into
swift-sheet-music** and both platforms call it. Android reaches it through a JNI bridge.

## Part 1 — swift-sheet-music: lift the tap→cursor pipeline

Move three pure functions out of Folino's Reader feature into ssm (no behavior change):

- `nearestCursor(at point: CGPoint, in document: LayoutDocument) -> ScoreCursor?`
  → **SheetMusicLayout** (needs `LayoutDocument` / `LayoutSystem` / `LayoutMeasure`, all in ssm).
- `Score.engineCursorForFilteredTap(_:hiddenStaves:)` and its helper
  `Score.unfilterStaffAddress(_:hidingStaves:)`
  → **SheetMusicCore** (pure `Score` structure math; `SheetMusicCore` only).

Add one combined public entry point in **SheetMusicLayout** that encapsulates the whole pipeline so
both platforms (and the JNI bridge) have a single source of truth:

```swift
@available(macOS 15.0, iOS 16.0, *)
public func nearestEngineCursor(
    at point: CGPoint, in document: LayoutDocument,
    score: Score, hiddenStaves: Set<StaffAddress>
) -> ScoreCursor?
// = nearestCursor(at:in:) then score.engineCursorForFilteredTap(_:hiddenStaves:)
// Returns an engine-ready (full-score-addressed) cursor, or nil if the tap hit no playable element.
```

`nearestCursor` becomes `public`. The display-side helpers that stay iOS-only
(`translateCursorForHiddenStaves`, `filterStaffAddress`, `resolveTickInMeasure`) are not moved.

### JNI bridge (SheetMusicAndroidJNI)

```swift
public func nativeNearestCursor(
    scoreHandle: Int64, tapXmm: Double, tapYmm: Double, hiddenStavesBytes: Data
) -> Data
```

- Look up the filtered `LayoutDocument` via `LayoutDocumentCache.value(for: scoreHandle)` and the
  `Score` via the existing score-handle registry.
- Convert mm → document points (`× 72.0 / 25.4`, inverse of the existing pt→mm convention used by
  `nativeCursorFrame` / `nativeMeasureFrame`).
- Decode `hiddenStavesBytes` into `Set<StaffAddress>` (reuse the existing hidden-staves wire codec
  used by the layout-compute path; add a small codec if none is directly reusable).
- Call `nearestEngineCursor(...)`; encode the result with `ScoreCursorCodec`. Return **empty `Data`**
  when the tap hit nothing (Kotlin treats empty as "no cursor", does nothing).

Kotlin binding `SheetMusicJNI.nativeNearestCursor(scoreHandle, tapXmm, tapYmm, hiddenStavesBytes)`
(swift-java/jextract), mirroring the existing `nativeCursorFrame` / `nativeMeasureFrame` bindings.

### ssm testing

Unit-test `nearestEngineCursor` in SheetMusicTests (Apple): build a small multi-staff score + its
`LayoutDocument`, assert (a) a tap near a known note returns that note's `.item(.note)`, (b) a tap on
a rest returns `.item(.rest)`, (c) with a staff hidden, the returned cursor carries the **full-score**
address (translation applied), (d) a tap in empty space returns nil. Existing PlaybackEngine suite
stays green.

## Part 2 — Folino iOS: adopt the shared logic

- Delete Folino's `NearestCursor.swift`; the three score surfaces keep calling `nearestCursor(at:in:)`
  — now resolved from `import SheetMusicLayout` (already imported).
- Move `engineCursorForFilteredTap` + `unfilterStaffAddress` out of Folino; `ReaderPlaybackSession`'s
  call site is unchanged (the method now comes from ssm `SheetMusicCore`).
- Re-pin Folino's swift-sheet-music to the new revision (4 `Package.swift` + `project.yml`).
- `NearestCursorTests` (Folino) stays green — it now exercises the lifted implementation through the
  same call. (If the test must move with the code, port it into SheetMusicTests; otherwise keep it as
  an integration guard in Folino.)

No iOS user-visible change — pure relocation guarded by the existing test.

## Part 3 — Android UI (Compose, FolinoReaderAndroid)

### ViewModel

Add to `ReaderAudioViewModel` (or the screen's interaction layer):

```kotlin
fun handleTap(cursor: ScoreCursor) {
    engine?.seek(to = cursor)                          // always move the cursor
    val playing = state.value == PlaybackState.PLAYING
    val note = (cursor as? ScoreCursor.Item)?.id as? ScoreItemID.Note
    if (!playing && note != null) engine?.playPreview(note.noteId, durationMillis = 500)
}
```

(Exact Kotlin shape follows the existing `ScoreCursor` / `ScoreItemID` sealed types and
`AndroidPlaybackEngine.seek` / `playPreview`.)

### Tap → mm conversion + the three modes

Each surface converts a Compose tap `Offset` (px) into document mm using the **same transform the
renderer already uses** to place the score (fit-scale × user zoom, plus the mode's scroll/page-Y
offset). The exact factors are read from the existing render code during implementation rather than
assumed. Then it calls `SheetMusicJNI.nativeNearestCursor(...)`, decodes the cursor, and calls
`handleTap`.

- **Vertical** (`ReaderScreen` ScorePage): add a `pointerInput { detectTapGestures }` that maps tap
  px → mm including the vertical scroll offset.
- **Horizontal** (`HorizontalScore`): same, including the horizontal scroll offset; tap y maps within
  the single-row natural-width layout.
- **Paged** (`PagedScore`): **center region = seek + audition; left/right edges = page navigation**
  (decided). Keep `PageTapOverlay`'s left/right nav zones; the central area (page width minus the two
  nav-zone widths) detects the seek tap. The tap's page-local offset is converted to absolute document
  mm using the page's Y band (`breaksMm[pageIndex]`) and the paged fit-scale.

### Audition policy (matches iOS)

Stopped/paused only; `.item(.note)` only (rest taps seek but are silent); single tapped note; 500 ms.
The not-playing guard lives in the ViewModel `handleTap`, mirroring iOS `ReaderPlaybackSession`.

## Data flow (Android)

```
Compose tap (px)
  └─ surface: px → document mm (renderer transform + scroll/page-Y offset)
       └─ SheetMusicJNI.nativeNearestCursor(handle, xmm, ymm, hiddenStavesBytes)
            └─ ssm: filtered LayoutDocument + Score → nearestEngineCursor → full-score ScoreCursor (Data)
       └─ decode ScoreCursor
       └─ ReaderAudioViewModel.handleTap → engine.seek(cursor); if !playing && note → playPreview(500ms)
```

## Verification

- **ssm**: `nearestEngineCursor` unit tests + full PlaybackEngine suite green (`swift test`, Apple).
- **iOS**: Folino `NearestCursorTests` + Reader audition tests green; full app builds with the new pin.
- **Android**: build the Android Reader, **install + launch on a physical Pixel** (per the Android
  workflow rule — Android changes are verified install+launch by Claude), then tap a note in each mode
  to confirm cursor moves + note sounds while paused. Hidden-staves case spot-checked via the Display
  Inspector.
- **Cross-repo gates**: the ssm engine/layout change is verified, **reported before push, and pushed
  only on approval**; Folino then re-pins. ssm example-app exercise is optional here since the audible
  path is verified directly in the Android app where the feature lives.

## Scope / sequencing

One feature, implemented in order: (1) ssm lift + bridge + tests, (2) ssm push (approval) , (3) Folino
re-pin + iOS adoption (build/tests green), (4) Android UI for all three modes + ViewModel wiring,
(5) Pixel install/launch verification. Audition is a thin add-on once seek works (the engine API
already exists on Android).

## Out of scope

- Long-press / drag-scrub on Android (separate interaction).
- Changing iOS behavior (pure relocation).
- Reworking the Display Inspector or page-navigation gestures beyond carving the paged center region.

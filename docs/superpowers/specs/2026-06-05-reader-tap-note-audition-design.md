# Reader Tap-Note Audition (iOS) — Design

**Date:** 2026-06-05
**Branch:** `worktree-reader-tap-note-audition`
**Scope:** iOS only. Android is a deliberately separate, larger follow-up task (see "Android — out of scope" below).

## Goal

In the Reader, tapping on (or near) a note already moves the playback cursor to that note. Add a short **audition**: play the tapped note's sound for ~0.5 s so the user hears the pitch they tapped — like MuseScore's "preview on selection".

## Behavior (decided)

- **Single tapped note only.** When a chord is tapped, play just the one note the tap resolved to (the `NoteID` `nearestCursor` already selected), not the whole chord.
- **Only when not playing.** Audition fires only while the engine is stopped/paused. During active playback, tapping keeps its existing behavior (move the cursor / seek) with no extra note — so a continuous-playback stream is never overlaid with a one-shot preview.
- **Rest taps produce no sound.** Tapping a rest moves the cursor (existing behavior) but auditions nothing.
- **Duration ~0.5 s**, velocity = engine default (96).

## Why this is small

`swift-sheet-music` (pinned revision `9dcd110`) already ships the single-note API on the iOS engine:

```swift
// SheetMusicAudioApple/PlaybackEngine.swift (@MainActor)
public func playPreview(
    noteID: NoteID,
    in score: Score,
    duration: TimeInterval = 0.3,
    velocity: UInt8 = 96,
)
```

It resolves the `NoteID` to a MIDI pitch, routes it to the staff's MIDI channel on the shared AUMIDISynth, and schedules the note-off on a background queue (non-blocking, fire-and-forget). No `swift-sheet-music` change is needed; we only wire it through Folino's three layers.

## Changes

### 1. Domain — `PlaybackController` protocol

`Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`

Add one method:

```swift
/// Briefly sound a single note (the staff's instrument) without disturbing the sequencer — used by the
/// Reader when the user taps a note while playback is stopped/paused, to audition the pitch they tapped.
/// `NoteID` is re-exported from `SheetMusicCore`. No-op if no score is loaded or the ID no longer resolves.
func playPreview(noteID: NoteID, duration: TimeInterval) async
```

- `velocity` is intentionally omitted from the protocol surface; the adapter passes the engine default (96).
- `NoteID` is already visible to Domain via `@_exported import SheetMusicCore` (`DomainExports.swift`), the same path `ScoreCursor` uses.

### 2. Infrastructure — `LivePlaybackController`

`Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`

Thin pass-through to the engine:

```swift
public func playPreview(noteID: NoteID, duration: TimeInterval) {
    guard let score = loadedScore else { return }
    engine.playPreview(noteID: noteID, in: score, duration: duration)
}
```

- `@MainActor` already; the protocol's `async` becomes a main-actor hop.
- No-op before a score is loaded (`loadedScore == nil`).
- The "only when not playing" policy is **not** enforced here — it lives in the feature (see below), keeping the adapter a faithful pass-through.

### 3. Feature — `ReaderPlaybackSession.setManualCursor(_:)`

`Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`

The three score surfaces (Vertical / Paged / Horizontal) already call `viewModel.playbackSession.setManualCursor(cursor)` on tap, so the tap sites need **no change**. We add the audition inside `setManualCursor`, after the existing hidden-staves translation:

```swift
func setManualCursor(_ cursor: ScoreCursor) {
    let hidden = hiddenStavesProvider()
    let engineCursor = scoreProvider()?.engineCursorForFilteredTap(
        cursor, hiddenStaves: hidden,
    ) ?? cursor
    rawPlaybackCursor = engineCursor
    playbackCursor = cursor
    onCursorChanged()
    guard let controller else { return }
    Task { await controller.setCursor(to: engineCursor) }

    // Audition the tapped note while stopped/paused only. Use the engine (full-score addressed)
    // cursor so the NoteID resolves against the score the engine prepared; skip rests.
    if !isPlaying, case let .item(.note(noteID)) = engineCursor {
        Task { await controller.playPreview(noteID: noteID, duration: 0.5) }
    }
}
```

Rationale:
- `engineCursor` (full-score addressing) is used rather than the filtered `cursor`, because `playPreview` resolves the `NoteID` against the full prepared score; a filtered staff address could resolve to the wrong staff or fail.
- `ScoreCursor.item(.note(NoteID))` is the shape `nearestCursor` produces for a note (`NearestCursor.swift:115`); `.item(.rest(_))` falls through and stays silent.
- Centralizing the policy in the session keeps it identical across all three surfaces.

## Testing (Swift Testing)

### Infrastructure
A fake/lightweight check that `LivePlaybackController.playPreview` is a no-op when no score is loaded. (The engine itself is `swift-sheet-music`'s concrete `PlaybackEngine`, not a protocol, so the adapter test focuses on the `loadedScore == nil` guard rather than asserting an engine call.)

### Feature
Inject a fake `PlaybackController` into `ReaderPlaybackSession` and verify:
- Tapping a note while **stopped** → `playPreview` called once with the resolved `NoteID` and `duration == 0.5`.
- Tapping a **rest** while stopped → `playPreview` not called.
- Tapping a note while **playing** → `playPreview` not called (cursor still set).

The fake records `playPreview` invocations (noteID + duration) and existing `setCursor` calls. `isPlaying` is driven through the session's existing play/observe path or a test seam.

## Verification

Per project CLAUDE.md (no-simulator-launch policy): the agent confirms `xcodebuild` build + tests green. Real device/simulator hands-on (actually hearing the 0.5 s note on tap) is left to the user's manual clean build.

## Android — out of scope (separate task)

Investigation found the **Android Reader has no tap-to-seek on the score at all** (only page-nav tap zones + a transport slider that seeks by time fraction). There is no `nearestCursor` equivalent reachable from Kotlin and no JNI bridge that maps a tap point to a `NoteID`. `AndroidPlaybackEngine.playPreview(noteId:…)` exists, but nothing can produce the `NoteID` at the tap site.

Adding this on Android therefore requires first building tap-to-seek: lifting `nearestCursor` into shared `swift-sheet-music` (per the iOS/Android parity policy that logic must be shared, not reimplemented in Kotlin), adding a `nativeNearestCursor` JNI bridge, and wiring a Compose tap gesture — a cross-repo, medium-sized effort needing example-app verification and a `swift-sheet-music` push + re-pin. It is intentionally deferred to its own task.

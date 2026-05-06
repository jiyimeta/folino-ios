# Reader long-press cursor seek (vertical mode)

Date: 2026-05-06
Status: Draft — pending implementation plan

## Goal

Let the user move the playback cursor manually by long-pressing anywhere
on the score in `ReaderView`. The cursor snaps to the nearest playable
event (note or rest) on the staff closest to the touch point. The change
is visual *and* audible: when audio is playing, playback seeks to the
chosen position and continues from there.

Scope is the **vertical layout mode only**. Page mode does not currently
render the playback cursor at all (it goes straight through `Canvas`,
no overlay), so making seek work without a visible target would feel
broken. Page-mode parity will be tracked as a separate effort that
first lands a cursor overlay on `PagedScoreView`.

## User-visible behaviour

| State            | Long-press result                                                |
|------------------|------------------------------------------------------------------|
| Stopped / paused | Cursor jumps; next `play()` starts there.                        |
| Playing          | Cursor jumps and audio seeks to the new position; playback continues. |
| No candidate     | No-op (e.g. an empty staff at the touched X).                    |

A short medium-impact haptic fires the moment the long-press succeeds, so
the user has a physical confirmation that the cursor moved.

Long-press does **not** toggle chrome (chrome is on plain tap). Pinch /
pan / page-mode tap zones are unaffected.

## Architecture

```
VerticalScoreContainer
  ├─ owns LayoutDocument (already)
  ├─ named coord space "scoreSurface"
  ├─ long-press gesture on score surface
  │   └─ on success: location → nearestCursor(at:in:) → ScoreCursor
  └─ ReaderViewModel.setManualCursor(_:)
                ├─ playbackCursor = cursor   (immediate visual)
                └─ playbackController?.setCursor(to: cursor)
                                     │
                                     ▼
                  LivePlaybackController.setCursor(to:)
                                     │
                                     ▼
                          PlaybackEngine.seek(to:)
                                     │
                                     └─ engine emits @Published currentCursor
                                          ↑
                                          └─ ReaderViewModel.playbackCursor (cursor stream)
```

### Why score surface, not gesture layer

`ReaderGestureLayer` wraps the score in `scaleEffect` + `offset` while
`VerticalScoreContainer` wraps it in `ScrollView`. Reverse-mapping a
gesture point in the gesture layer back to document coordinates means
inverting two transforms plus the scroll offset — fragile, especially
with mid-pinch gestures.

Attaching the long-press gesture directly to the score surface inside
`VerticalScoreContainer` means the gesture's location is **already in
score-surface local coordinates**, which match `LayoutDocument` coords.
No transform inversion needed.

### Capturing the long-press location

`LongPressGesture` alone does not carry a location. We compose:

```swift
DragGesture(minimumDistance: 0, coordinateSpace: .named("scoreSurface"))
    .simultaneously(with: LongPressGesture(minimumDuration: 0.5, maximumDistance: 10))
```

When the `LongPressGesture` reports success, we read the most recent
`DragGesture` location and feed it to `nearestCursor(at:in:)`. The drag
gesture is set to `minimumDistance: 0` so a stationary press still
produces a value; `maximumDistance` on the long press kills the gesture
if the finger moves too far during the hold.

## Hit-test: `nearestCursor(at:in:)`

Helper in the Reader package:

```swift
func nearestCursor(at point: CGPoint, in document: LayoutDocument) -> ScoreCursor?
```

Algorithm:

1. **System** — pick the system whose Y range contains `point.y`. If
   none does, pick the system whose Y range is closest. (A press above
   the first system snaps to system 0; below the last, to the last.)
2. **Staff** — within that system, find the staff index `i` minimising
   `|point.y - (system.origin.y + system.staffOrigins[i].y + staffMidY)|`.
   Use the staff's vertical mid (≈ 2 sp from its origin) so a press in
   the gap between staves snaps to the closer one cleanly.
3. **Measure** — among `system.measures`, pick the measure whose
   X range contains `point.x`. Otherwise the closest by edge distance.
4. **Element** — walk the measure's elements; keep `.chord` and `.rest`
   variants that belong to the chosen staff. Staff membership is
   resolved by Y band (the element's origin Y is within ±2.5 sp of the
   chosen staff's centerline) so we don't depend on
   `LayoutChordNote.staffIndex` (which isn't carried directly).
   From the candidate set, pick the one whose anchor X is closest to
   `point.x`.
5. **Result** — return `.item(.note(noteID))` for chords (use the first
   `LayoutChordNote.noteID` of the chosen chord), `.item(.rest(restID))`
   for rests. Return `nil` if step 4 finds no candidate.

The X anchor for a chord is the first note's `origin.x + mirrorDx`
(matches `ScoreHitTester` conventions). For a rest, `origin.x`.

## Domain change: `PlaybackController.setCursor`

Replace

```swift
func setCursor(to chord: ChordPath) async
```

with

```swift
func setCursor(to cursor: ScoreCursor) async
```

Reasoning:

- The new cursor must be able to land on a **rest** — `ChordPath`
  (system / measure / voice / chord index) cannot represent rests.
- `PlaybackEngine.seek(to:)` already takes `ScoreCursor`. Going through
  `ChordPath` would mean reconstructing layout coordinates the engine
  has no use for.
- The current `setCursor(to: ChordPath)` adapter is a stub; no caller.
  `ChordPath` stays in Domain for `ABRepeatRange`, which still suits its
  point-and-shoot, chord-anchored use.

`LivePlaybackController.setCursor(to:)` becomes a one-liner that calls
`engine.seek(to: cursor)`. The engine's `@Published currentCursor`
republishes via the Combine sink already wired in `init`, which feeds
`ReaderViewModel.playbackCursor` through the existing `cursor` async
stream — so the highlight follows along automatically.

## ReaderViewModel API

New method:

```swift
public func setManualCursor(_ cursor: ScoreCursor) {
    playbackCursor = cursor               // immediate visual update
    guard let controller = playbackController else { return }
    Task { await controller.setCursor(to: cursor) }
}
```

The local `playbackCursor` write is intentional: it gives instant
feedback even when no playback controller is wired (previews, headless
tests, scores never loaded into playback). When a controller *is* wired,
the engine will republish the same cursor a tick later — that re-write
to the same value is a harmless no-op.

## Edge cases

| Case                          | Behaviour                                            |
|-------------------------------|------------------------------------------------------|
| Press in the empty margin     | Snap to nearest system → nearest staff → nearest event. |
| Press on a measure rest       | Snap to that rest (`.item(.rest(...))`).             |
| Press on a system gap         | Y distance picks the nearer system.                  |
| Long-press during pinch       | Allowed via `simultaneously`. Movement > 10 pt cancels the long press. |
| Score has no events at all    | `nearestCursor` returns `nil`; no-op.                |
| Score not yet loaded into engine | Visual cursor updates; seek call is skipped.       |
| Manual cursor while playing   | Engine seeks; `currentCursor` republishes; UI follows. |

## Testing

Swift Testing in `ReaderTests` target.

- **`NearestCursorTests`** — feed a hand-built `LayoutDocument` to
  `nearestCursor(at:in:)`:
  - Press inside notehead → returns that note's `.item(.note(id))`
  - Press on a rest → returns `.item(.rest(id))`
  - Press in the gap between two staves → returns event on the nearer staff
  - Press above the first system → returns first system's first event
  - Press in an empty measure → returns `nil` (or nearest event on chosen staff)
- **`ReaderViewModelManualCursorTests`** — extend `FakePlaybackController`
  with a `recordedSetCursorCalls: [ScoreCursor]`. Verify:
  - `setManualCursor(c)` updates `playbackCursor` immediately
  - `setManualCursor(c)` forwards to controller exactly once
  - With `playbackController == nil`, only the local cursor changes

UI gesture wiring (long-press location capture, haptic firing) is
verified manually in the simulator — Swift Testing can't drive
`LongPressGesture` and snapshot/preview testing for press gestures
isn't worth its weight here.

## Out of scope

- Page-mode support (waits on a `PagedScoreView` cursor overlay).
- Drag-to-scrub (long-press then drag continuously). The current
  product targets a single jump per press.
- A–B repeat range editing via long-press.
- Undo for cursor moves.

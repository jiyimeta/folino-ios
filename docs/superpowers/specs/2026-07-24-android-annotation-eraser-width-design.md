# Android annotation: eraser and per-pen stroke width

Date: 2026-07-24
Status: approved design, not yet implemented

## Problem

The Android annotation toolbar shipped as a minimum: four fixed colour swatches and one hard-coded
stroke width (`ANNOTATION_BASE_WIDTH_SP = 1.2f`, `ReaderScreen.kt:128`). There is no eraser, no way to
change the width, and no undo. iOS gets all three from the system `PKToolPicker`
(`AnnotationCanvasView.swift:272`), so this is an Android parity gap rather than a new product
capability.

The stored ink format does not change. Erasing rewrites the annotation layer into new
`DrawingAnchorWire` values in the existing schema, and Room stores one opaque blob per score
(`RoomAnnotationStore.kt`), so more and smaller drawings are format-transparent. No migration.

## Scope

In scope:

- A partial ("pixel") eraser that removes the parts of a stroke the eraser passes over.
- Four preset widths per palette colour, and four for the eraser.
- A width picker that opens by re-tapping the already-selected tool.
- Palette swatches drawn at a size that shows each pen's current width.
- Undo/redo covering both drawing and erasing.
- Persisting the pen setup across app restarts.

Out of scope:

- iOS changes. `PKToolPicker` already provides an eraser and a width slider.
- New tools (highlighter, pencil). The neutral model already carries them; the toolbar does not.
- A custom colour picker. The palette stays the four fixed presets.

Annotation mode is already restricted to the VERTICAL layout and to a non-playing Reader
(`annotationEnabled` in `ReaderScreen.kt`). The eraser and the width picker inherit that restriction;
PAGE and HORIZONTAL are untouched.

## Tool state

```kotlin
sealed interface AnnotationTool {
    data class Pen(val colorIndex: Int) : AnnotationTool   // index into the fixed palette, 0..3
    data object Eraser : AnnotationTool
}

data class AnnotationToolState(
    val selected: AnnotationTool,
    val penWidths: List<Float>,   // one per palette colour, document-mm
    val eraserWidth: Float,       // document-mm
)
```

Width is per palette colour, so the four swatches behave as four pens: black can be thin while red is
thick. Only the widths and the selected tool are state; the colours themselves stay the fixed presets
in `AnnotationToolbarDefaults.DEFAULT_COLORS`.

### Preset values

Units are document-mm, the same world unit `InkBrushMapping.brushFor` already takes, and all preset
values are **widths (diameters)**. The eraser's geometric radius is therefore `eraserWidth / 2`. One
staff space is roughly 1.75mm, which is the scale to judge these against.

| | Preset 1 | Preset 2 | Preset 3 | Preset 4 |
| --- | --- | --- | --- | --- |
| Pen | 0.6 | 1.2 (default) | 2.0 | 3.2 |
| Eraser | 2.0 | 4.0 (default) | 8.0 | 14.0 |

The pen default is the currently shipping 1.2, so existing behaviour is preserved for anyone who never
opens the picker. Treat both rows as starting values to be tuned by eye on device.

### Persistence

`FolinoReaderAndroid` cannot depend on the app module's `SettingsPrefs` — that would invert the
`app -> FolinoReaderAndroid` dependency, the same boundary the existing display-settings plumbing
respects. Tool state therefore travels the identical route as `LayoutOptions`, which is **props in, a
callback out** rather than the app module touching the view model:

1. The app module collects the DataStore flows and assembles an `AnnotationToolState`.
2. It passes that in as a `ReaderScreen` parameter, alongside an `onAnnotationToolStateChange`
   callback — mirroring today's `displayOptions` / `onDisplayOptionsChange` pair in `MainActivity`.
3. `ReaderScreen` pushes the snapshot into the view model from a `LaunchedEffect(toolState)`, exactly
   as it already does for `setLayoutOptions` (`ReaderScreen.kt:351`). The app module never holds a
   `ReaderViewModel` reference; the view model is a `viewModel()` default inside `ReaderScreen`.
4. Toolbar edits go out through the callback, and the app module writes them to DataStore.

Keys: `annotation_pen_width_0..3`, `annotation_eraser_width`, `annotation_selected_tool`.

## Eraser

### Where the logic lives

The erase geometry goes in shared Swift, reached over the existing JNI bridge, because a Kotlin-only
implementation would be exactly the divergent reimplementation the repo's parity rule forbids. It also
lands where the work actually has to happen: erasing rewrites the persisted, anchor-relative
representation, which is a Domain concept, not an androidx.ink one.

`AnnotationAnchoringCore.place(_:with:)` already puts a stored stroke into document-mm, which is the
half of the round trip the erase geometry needs.

### The anchoring constraint, and the two-phase apply

Re-anchoring cannot happen inside the erase call. `FolinoReaderJNI` depends only on `Domain`,
`ReaderAnnotationCore`, swift-java and Wirelet (`Packages/Features/Reader/Package.swift:84-92`) — it
has no access to swift-sheet-music, so it cannot resolve an anchor for a point. That is why the
existing capture flow is Kotlin-orchestrated across four calls, with Kotlin resolving the anchor
through ssm's `SheetMusicJNI` *before* handing prefetched values to Swift
(`AnnotationCaptureController.kt`), and why `PrefetchedAnchorResolver` exists at all. A fragment's
representative point is only known after the split, so it cannot be prefetched.

Erase therefore applies in two phases:

**Phase 1 — during the drag, throttled.** One `nativeAnnotationErase` call. Fragments **inherit the
parent drawing's anchor**: the six anchor fields are copied unchanged and only `encodedDrawing` is
replaced with the sliced stroke. Because the stored geometry is anchor-relative, an inherited-anchor
fragment renders in exactly the place it was drawn — the inheritance is invisible until a reflow, and
no reflow happens mid-drag.

**Phase 2 — on `ACTION_UP`.** The strokes the gesture changed are re-anchored through the existing
Kotlin capture pipeline, giving each fragment its own anchor. This is what makes the final state match
iOS, where `canvasViewDrawingDidChange` hands the whole canvas back and re-captures it after any edit,
erases included (`AnnotationCanvasView.swift:214-221`).

Only the drawings the erase actually modified are re-anchored, not the whole layer: untouched drawings
already carry correct anchors, and per-fragment anchor resolution costs one `nativeResolveAnchor` call
each.

### The erase call

New file `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationEraseCore.swift`:

```swift
public enum AnnotationEraseCore {
    public static func erase(
        _ drawings: [DrawingAnchor],
        transforms: [StrokeTransform?],   // from the existing display(_:using:) path
        path: [CGPoint],                  // eraser centreline, document-mm
        radiusMm: Double
    ) -> EraseResult
}

public struct EraseResult {
    public let drawings: [DrawingAnchor]
    /// Indices into the RETURNED array whose geometry changed, so the caller knows what to re-anchor.
    public let changedIndices: [Int]
}
```

Taking `transforms` rather than an `AnchorResolving` keeps the call honest about what it can do: it
places and cuts, it does not resolve.

Algorithm, per drawing:

1. `place()` the stroke into document-mm using its transform. A drawing whose transform is `nil` or
   whose `sp == 0` is unresolved this layout — it cannot be placed, so it is passed through untouched
   and never erased.
2. Mark a stroke **segment** erased when its distance to the eraser polyline is
   `<= radiusMm + halfWidth`, where `halfWidth = max(width[i], baseWidthSp) / 2` after placement.
   Testing segments rather than sample points matters: samples are spaced by drawing speed, and an
   eraser crossing perpendicular between two samples of a fast stroke would otherwise erase neither
   endpoint and appear to do nothing. Per-point `width[]` is currently 0 for every Android-authored
   stroke (`InkStrokeSerialization.kt:24` writes 0 in v1), so `baseWidthSp` is the value that actually
   carries the thickness today; taking the max keeps the test correct if per-point widths are
   populated later.
3. Split the surviving samples into maximal contiguous runs. Cuts land on sample boundaries, so an
   erased edge can be up to one sample-interval ragged; that is accepted for v1.
4. Drop runs shorter than two points. androidx.ink renders a single-input stroke as a dot, so keeping
   them would leave stray dots along an erased path.
5. Then:
   - no segment erased: return the drawing unchanged and do not list it in `changedIndices`, so an
     erase that misses produces no diff at all;
   - every segment erased: drop the drawing;
   - otherwise: slice the parallel arrays per run into a new `InkStroke`. `x`, `y` and `width` are
     always present and stay index-aligned; `force`, `azimuth`, `altitude` and `timeMillis` may be
     empty (`InkStroke.swift:27-28` — Android never populates `azimuth`/`altitude`,
     `InkStrokeRawFields.swift`), and an empty array stays empty rather than being padded.

`changedIndices` empty means the gesture did nothing: no save, no undo entry, no phase 2.

### JNI

One new entry point, alongside the existing `nativeAnnotationDisplayTransforms`:

```
nativeAnnotationErase(drawingsBytes, transformsBytes, eraseRequestBytes) -> EraseResultWire bytes
```

`eraseRequestBytes` is a new `@WireFormat` carrying the path points and the radius; `EraseResultWire`
carries the new drawings plus `changedIndices`. Returning a struct rather than a bare list keeps the
established "empty `Data` means the call failed" convention usable (`ReaderAnnotationJNI.kt:14-15`) —
an empty result is a decode failure and must leave the layer alone, which is a different outcome from
a successful erase that changed nothing.

List framing must use the Wirelet `Array: WireFormat` framing (varint byte-length plus
length-delimited elements) that Swift's `[T](decoding:)` expects — not the observable `WireletList`
framing. `AnnotationCaptureController` documents this trap in full; mis-framing makes the Swift decode
throw and the call silently return empty.

### Input handling

While the eraser is selected, the wet overlay must not start an androidx.ink stroke. It collects the
pointer path instead, converted to document-mm by the same `screenToWorld` matrix the pen path uses.

Erase applies during the drag, not only on lift, because waiting until the finger comes up feels
broken. Apply on a throttle — roughly every 50ms or every N points — with the final apply and the
phase-2 re-anchor on `ACTION_UP`.

Gesture interruption: a second pointer going down (which today cancels the wet stroke and hands the
gesture to the parent for pan/zoom, `AnnotationWetOverlay.kt`) and `ACTION_CANCEL` both **keep** what
has already been erased and run phase 2. Erasing is incremental and already visible on screen;
silently restoring it would be more surprising than keeping it, and the `ACTION_DOWN` undo entry makes
it recoverable either way. A single tap is a one-point path, which erases a disc of the eraser's
radius.

## Undo/redo

The layer is an immutable `List<DrawingAnchorWire>`, so history is a stack of snapshots held by
reference rather than a diff log.

`ReaderViewModel` gains undo and redo stacks and funnels every mutation through one choke point:

```kotlin
private fun applyDrawings(
    pushHistory: Boolean,
    persist: Boolean,
    transform: (List<DrawingAnchorWire>) -> List<DrawingAnchorWire>,
)
```

Three details are load-bearing:

- **It takes a transform, not a new list.** Pen commits land asynchronously from `Dispatchers.Default`
  coroutines, which is why `addDrawing` uses an atomic `_drawings.update { it + drawing }` today. An
  erase apply that wrote back a list captured at `ACTION_DOWN` would silently drop a pen stroke that
  committed in between. Every mutation is a function of the current value, and erase applies chain off
  the previous apply's output rather than off the gesture's opening snapshot.
- **`persist` is separate from `pushHistory`.** Rehydration on score open must do neither, or opening
  a score would arm a debounced save echoing back what was just loaded. Throttled erase applies push
  no history and do not persist; `drawingsChanged` is called once per gesture, at `ACTION_UP`, after
  phase 2. That keeps the "one place calls `drawingsChanged`" property while avoiding re-marshalling
  the whole layer across JNI twenty times a second (`AnnotationSaveBridge.swift` decodes the full list
  on every call; the debounce coalesces disk writes, not marshalling).
- **It releases the wet→dry handoff queue.** `AnnotationHandoffQueue.onDryRendered` retires a retained
  wet copy by matching the committed wire's identity against the rendered layer. Undo — or an erase —
  removes that identity before the dry layer ever paints it, so the androidx.ink copy would keep
  drawing an undone stroke for the full `MAX_WET_RETENTION_MS` (2s). Any mutation that is not a plain
  append calls `releaseAll()`.

Rules:

- One history entry per gesture. An erase drag applies many times under the throttle but pushes only
  the layer as it stood at `ACTION_DOWN`, so one stroke of the eraser costs one undo.
- Session-scoped. Both stacks clear when the score closes or the Reader is retargeted, and nothing is
  persisted.
- Depth capped at 30 to bound memory.
- Any new mutation clears the redo stack.

Consolidating also removes today's duplicated `saveController.drawingsChanged` calls in `addDrawing`
and `removeDrawing`.

## Toolbar

```
[ eraser ] [ ●  ●   ●    ● ] [ undo  redo ]
                ^ circle diameter tracks that pen's current width
```

- Swatches become circles whose diameter maps to the colour's width preset, so every pen's thickness
  is legible without opening anything. They are currently 30dp rounded squares at a fixed size.
- The selected swatch carries a ring.
- Re-tapping the **selected** pen, or the selected eraser, opens a Material 3 `Popup` anchored to it
  holding the four presets as circles. Tapping one applies it and dismisses.
- Tapping an **unselected** swatch only moves the selection; it does not open the picker.
- The eraser button shows its own current size the same way when selected.
- Width on a 411dp phone: eraser 40 + four swatches at up to 36 with spacing ≈ 176 + undo/redo 80,
  about 300dp.

This is the Android idiom (Keep, Samsung Notes) rather than a `PKToolPicker` clone, per the repo rule
that UI placement follows platform convention while behaviour matches iOS.

## Testing

Swift unit tests for `AnnotationEraseCore`:

- A miss leaves the layer identical and returns empty `changedIndices`.
- An eraser crossing a stroke's middle yields two fragments.
- Covering a whole stroke drops it.
- Single-point remnants are discarded.
- An eraser crossing a segment between two distant samples still cuts it (the sparse-sampling case).
- A thick stroke erases on an edge touch that misses its centreline, driven by `baseWidthSp`.
- Present arrays stay index-aligned after slicing; absent optional channels stay empty.
- A drawing with an unresolved transform passes through untouched.

Kotlin unit tests:

- Undo/redo: one entry per gesture, redo cleared by a new mutation, depth cap, stacks cleared on score
  change.
- `applyDrawings` composes correctly when a pen commit interleaves with an erase apply.
- Width preset mapping and the tool-state round trip through DataStore.

On-device verification: erase across a stroke and confirm the surviving fragments stay anchored
through a reflow (the phase-2 re-anchor is what this proves); undo immediately after finger-up and
confirm no ghost stroke lingers; confirm the pen setup survives an app restart.

## Risks

- **Erase throughput.** Every throttled apply re-places the whole layer in the dry overlay. Measure on
  a dense score before trusting it. If it stutters, re-place only the drawings the erase changed —
  `changedIndices` already carries what is needed.
- **Phase-2 anchoring failures.** A fragment landing off-staff resolves to nothing, and `capture()`
  returns nothing for it. The re-anchor pass must treat that as "this fragment is gone" and keep the
  rest of the layer, never discarding a whole drawing because one of its fragments failed.
- **Ragged cut edges.** Cuts land on sample boundaries, so a slow-sampled stroke can erase slightly
  more or less than the eraser outline suggests.
- **Preset values are guesses.** Both rows need a pass by eye on device.

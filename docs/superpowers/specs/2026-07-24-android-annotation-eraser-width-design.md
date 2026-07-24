# Android annotation: eraser and per-pen stroke width

Date: 2026-07-24
Status: approved design, not yet implemented

## Problem

The Android annotation toolbar shipped as a minimum: four fixed colour swatches and one hard-coded
stroke width (`ANNOTATION_BASE_WIDTH_SP = 1.2f`). There is no eraser, no way to change the width, and
no undo. iOS gets all three from the system `PKToolPicker` (`AnnotationCanvasView.swift:272`), so this
is an Android parity gap rather than a new product capability.

Nothing about the stored ink format changes. Erasing rewrites the annotation layer into new
`DrawingAnchorWire` values in the existing schema, so there is no migration.

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

Units are document-mm, the same world unit `InkBrushMapping.brushFor` already takes. One staff space
is roughly 1.75mm, which is the scale to judge these against.

| | Preset 1 | Preset 2 | Preset 3 | Preset 4 |
| --- | --- | --- | --- | --- |
| Pen | 0.6 | 1.2 (default) | 2.0 | 3.2 |
| Eraser | 2.0 | 4.0 (default) | 8.0 | 14.0 |

The pen default is the currently shipping 1.2, so existing behaviour is preserved for anyone who never
opens the picker. Treat both rows as starting values to be tuned by eye on device.

### Persistence

`FolinoReaderAndroid` cannot depend on the app module's `SettingsPrefs` — that would invert the
`app -> FolinoReaderAndroid` dependency, the same boundary the existing display-settings plumbing
respects. Tool state therefore travels the identical route as `LayoutOptions`:

1. The app module collects the DataStore flows and assembles an `AnnotationToolState`.
2. It pushes the snapshot in with `readerVm.setAnnotationToolState(state)`.
3. Toolbar edits go back out through a callback the app module persists.

Keys: `annotation_pen_width_0..3`, `annotation_eraser_width`, `annotation_selected_tool`.

## Eraser

### Where the logic lives

The erase geometry goes in shared Swift, reached over the existing JNI bridge, because a Kotlin-only
implementation would be exactly the divergent reimplementation the repo's parity rule forbids. It also
lands where the work actually has to happen: erasing rewrites the persisted, anchor-relative
representation, which is a Domain concept, not an androidx.ink one.

`AnnotationAnchoringCore` already supplies both halves of the round trip — `place(_:with:)` puts a
stored stroke into document-mm, and `capture(strokes:using:)` takes document-mm strokes back to
anchored `DrawingAnchor`s.

New file `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationEraseCore.swift`:

```swift
public enum AnnotationEraseCore {
    public static func erase(
        _ drawings: [DrawingAnchor],
        using resolver: AnchorResolving,
        path: [CGPoint],      // eraser centreline, document-mm
        radiusMm: Double
    ) -> EraseResult
}

public struct EraseResult {
    public let drawings: [DrawingAnchor]
    public let changed: Bool
}
```

Algorithm, per drawing:

1. Resolve its `StrokeTransform` through the existing `display(_:using:)` path and `place()` the stroke
   into document-mm.
2. Mark point *i* erased when `distanceToPolyline(point_i, path) <= radiusMm + width[i] / 2`. Using the
   stroke's own per-point width means a thick stroke erases when the eraser touches its edge, not only
   its centreline, without needing androidx.ink's mesh geometry.
3. Split the surviving indices into maximal contiguous runs. Drop runs shorter than two points — a
   single-point remnant renders as nothing and would only clutter the layer.
4. Then:
   - no point erased: return the drawing unchanged, without re-anchoring, so an erase that misses
     produces no diff;
   - every point erased: drop the drawing;
   - otherwise: slice every parallel array (`x`, `y`, `width`, `force`, `azimuth`, `altitude`,
     `timeMillis`) per run into a new `InkStroke`, and `capture()` each run so every fragment gets its
     own anchor.

`changed` is false when no drawing was touched, so a no-op erase neither marks the layer dirty nor
pushes an undo entry.

### JNI

One new entry point, symmetrical with the existing `nativeAnnotationDisplayTransforms`:

```
nativeAnnotationErase(drawingsBytes, refPointsBytes, eraseRequestBytes) -> [DrawingAnchorWire] bytes
```

`eraseRequestBytes` is a new `@WireFormat` carrying the path points and the radius. List framing must
use the Wirelet `Array: WireFormat` framing (varint byte-length plus length-delimited elements) that
Swift's `[T](decoding:)` expects — not the observable `WireletList` framing. `AnnotationCaptureController`
documents this trap in full; mis-framing makes the Swift decode throw and the call silently return
empty.

### Input handling

While the eraser is selected, the wet overlay must not start an androidx.ink stroke. It instead
collects the pointer path, converted to document-mm by the same `screenToWorld` matrix the pen path
uses.

Erase applies during the drag, not only on lift, because waiting until the finger comes up feels
broken. Apply on a throttle — roughly every 50ms or every N points — with a final apply on
`ACTION_UP`.

Each apply replaces the layer, which re-runs the dry overlay's placement recompute for every drawing.
That is a real cost on a large layer and needs measuring on device. If it stutters, the fix is to
re-place only the drawings the erase actually changed rather than the whole layer; that optimisation
is deliberately deferred until there is a measurement justifying it.

## Undo/redo

The layer is an immutable `List<DrawingAnchorWire>`, so history is a stack of snapshots held by
reference rather than a diff log.

`ReaderViewModel` gains undo and redo stacks and funnels every mutation through one choke point:

```kotlin
private fun applyDrawings(new: List<DrawingAnchorWire>, pushHistory: Boolean)
```

Drawing commits, erase applies, undo, redo, and rehydration all go through it, and it is the single
place that calls `saveController.drawingsChanged`. Today that call is duplicated across `addDrawing`
and `deleteDrawing`; consolidating removes the chance of a future mutation forgetting to save.

Rules:

- One history entry per gesture. An erase drag applies many times under the throttle but pushes only
  the layer as it stood at `ACTION_DOWN`, so one stroke of the eraser costs one undo.
- Session-scoped. Both stacks clear when the score closes or the Reader is retargeted, and nothing is
  persisted.
- Depth capped at 30 to bound memory.
- A redo stack cleared by any new mutation.

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

- Swift unit tests for `AnnotationEraseCore`: a miss leaves the layer identical and reports
  `changed == false`; an eraser crossing a stroke's middle yields two fragments; covering a whole
  stroke drops it; single-point remnants are discarded; every parallel array stays the same length as
  `x` after slicing; a thick stroke erases on an edge touch that misses its centreline.
- Kotlin unit tests for the undo/redo stacks: one entry per gesture, redo cleared by a new mutation,
  depth cap, stacks cleared on score change.
- Kotlin unit tests for width preset mapping and the tool-state round trip through DataStore.
- On-device verification: erase across a stroke and confirm the surviving fragments stay anchored
  through a reflow; confirm the pen setup survives an app restart.

## Risks

- **Erase throughput.** Every throttled apply currently re-places the whole layer. Measure before
  trusting it on a dense score.
- **Fragment anchoring.** Each fragment re-anchors independently, so a fragment landing off-staff can
  fail to resolve and be dropped. `capture()` already returns nothing for unresolvable strokes; the
  erase path must treat that as "this fragment is gone" rather than losing the whole drawing.
- **Preset values are guesses.** Both rows need a pass by eye on device.

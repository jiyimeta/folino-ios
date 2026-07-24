# Android annotation eraser and per-pen width — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Android annotation toolbar a partial eraser, four width presets per pen and for the eraser, and undo/redo, with the pen setup persisted.

**Architecture:** The erase geometry lives in shared Swift (`AnnotationEraseCore`) reached over the existing `FolinoReaderJNI` bridge, because `FolinoReaderJNI` has no swift-sheet-music dependency and therefore cannot resolve anchors. Erase applies in two phases: during the drag one JNI call cuts strokes with fragments inheriting the parent's anchor (invisible until a reflow), and on finger-up the changed strokes re-anchor through the existing Kotlin capture pipeline. All layer mutations funnel through one view-model choke point that owns undo/redo, persistence gating, and the wet→dry handoff release.

**Tech Stack:** Swift 6.3 (shared core + JNI), Kotlin/Compose (Android UI), androidx.ink 1.0, swift-wirelet `@WireFormat` codecs, Room + DataStore.

**Design spec:** `docs/superpowers/specs/2026-07-24-android-annotation-eraser-width-design.md`

## Global Constraints

- Worktree: `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-annotation-eraser-width`. Run every command from there; never `cd` to the primary checkout.
- All preset values are **widths (diameters)** in document-mm. The eraser's geometric radius is `eraserWidth / 2`.
- Pen presets: `0.6, 1.2, 2.0, 3.2` — default `1.2` (today's `ANNOTATION_BASE_WIDTH_SP`).
- Eraser presets: `2.0, 4.0, 8.0, 14.0` — default `4.0`.
- Undo depth cap: `30`. Undo history is session-scoped and never persisted.
- Erase throttle during a drag: apply at most every `50ms`.
- No Kotlin reimplementation of shared logic. Geometry belongs in `ReaderAnnotationCore`.
- `FolinoReaderAndroid` must not depend on the app module. Tool state arrives as `ReaderScreen` props with a change callback, exactly like `displayOptions` / `onDisplayOptionsChange`.
- Wire lists use Wirelet `Array: WireFormat` framing (varint byte-length + length-delimited elements), never `WireletList` framing. See the comment block in `AnnotationCaptureController.kt`.
- Comment reflow budget is 120 columns.
- Swift tests use Swift Testing (`@Suite`, `@Test`, `#expect`). Kotlin unit tests use JUnit 4.
- Annotation mode is VERTICAL-layout-only and disabled during playback; the new tools inherit that.

**Swift test command** (from `Packages/Features/Reader`):

```bash
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationEraseCoreTests
```

**Kotlin test command:**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests '<pattern>'
```

**`.so` rebuild** (needed after any Swift change under `Packages/Features/Reader/Sources/`):

```bash
Scripts/android-build-reader-libs.sh
```

Takes roughly 5-8 minutes. If it fails with `attempt to write a readonly database`, run
`chmod -R u+w Packages/Features/Reader/.build/checkouts/swift-wirelet` first.

---

## File Structure

**Create:**

- `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationEraseCore.swift` — erase geometry and stroke slicing. Pure, no JNI, no layout.
- `Packages/Features/Reader/Tests/ReaderTests/AnnotationEraseCoreTests.swift`
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationToolState.kt` — tool selection, presets, width lookup.
- `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ink/AnnotationToolStateTest.kt`
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationWidthPicker.kt` — the re-tap popup.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationEraseController.kt` — sequences the two-phase erase, mirroring `AnnotationCaptureController`.
- `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/DrawingHistoryTest.kt`

**Modify:**

- `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift` — add `EraseRequestWire`, `EraseResultWire`.
- `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift` — add `nativeAnnotationErase`.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt` — add `erase`.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt` — `applyDrawings` choke point, undo/redo, tool state.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationToolbar.kt` — circles, eraser, undo/redo.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationWetOverlay.kt` — eraser input path.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` — wiring and props.
- `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` and the settings DataStore — persistence.

---

## Task 1: Erase geometry in shared Swift

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationEraseCore.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationEraseCoreTests.swift`

**Interfaces:**
- Consumes: `AnnotationAnchoringCore.place(_:with:)`, `StrokeTransform`, `DrawingAnchor`, `InkStroke`, `InkStrokeCodec` — all existing.
- Produces:
  ```swift
  public struct EraseResult: Sendable {
      public let drawings: [DrawingAnchor]
      public let changedIndices: [Int]   // indices into `drawings`
  }
  public enum AnnotationEraseCore {
      public static func erase(
          _ drawings: [DrawingAnchor],
          transforms: [StrokeTransform?],
          path: [CGPoint],
          radiusMm: CGFloat
      ) -> EraseResult
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `AnnotationEraseCoreTests.swift`. These tests build `DrawingAnchor`s directly from encoded strokes with a known identity transform, so no layout engine is involved.

```swift
import Domain
import Foundation
import ReaderAnnotationCore
import Testing

@Suite("AnnotationEraseCore")
struct AnnotationEraseCoreTests {
    /// Anchor-relative stroke from document-mm samples. With an identity transform (sp 1, p 0) the
    /// stored geometry IS the document geometry, so tests can reason in document-mm directly.
    private func drawing(_ points: [(Float, Float)], baseWidth: Float = 0.5) -> DrawingAnchor {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: baseWidth, opacity: 1,
            x: points.map(\.0), y: points.map(\.1), width: points.map { _ in 0 },
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        return DrawingAnchor(
            kind: .musical(MusicalAnchor(measureIndex: 0, tickInMeasure: 0, partIndex: 0,
                                         staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0)),
            encodedDrawing: InkStrokeCodec.encode(stroke),
        )
    }

    private let identity = StrokeTransform(sp: 1, px: 0, py: 0)

    private func decoded(_ d: DrawingAnchor) -> InkStroke {
        InkStrokeCodec.decode(d.encodedDrawing)!
    }

    @Test("a miss leaves the layer untouched")
    func missChangesNothing() {
        let layer = [drawing([(0, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [identity],
                                            path: [CGPoint(x: 5, y: 50)], radiusMm: 1)
        #expect(out.changedIndices.isEmpty)
        #expect(out.drawings.count == 1)
        #expect(decoded(out.drawings[0]).x == decoded(layer[0]).x)
    }

    @Test("erasing the middle yields two fragments")
    func splitsInTwo() {
        let layer = [drawing([(0, 0), (2, 0), (4, 0), (6, 0), (8, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [identity],
                                            path: [CGPoint(x: 5, y: 0)], radiusMm: 1.2)
        #expect(out.drawings.count == 2)
        #expect(out.changedIndices.sorted() == [0, 1])
        #expect(decoded(out.drawings[0]).x.allSatisfy { $0 < 5 })
        #expect(decoded(out.drawings[1]).x.allSatisfy { $0 > 5 })
    }

    @Test("covering the whole stroke drops it")
    func dropsFullyErased() {
        let layer = [drawing([(0, 0), (1, 0), (2, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [identity],
                                            path: [CGPoint(x: 1, y: 0)], radiusMm: 10)
        #expect(out.drawings.isEmpty)
        #expect(out.changedIndices.isEmpty)
    }

    @Test("single-point remnants are discarded")
    func dropsSinglePointRuns() {
        // Erasing everything but the last sample leaves a 1-point run, which must not survive.
        let layer = [drawing([(0, 0), (1, 0), (2, 0), (20, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [identity],
                                            path: [CGPoint(x: 1, y: 0)], radiusMm: 5)
        #expect(out.drawings.isEmpty)
    }

    @Test("an eraser crossing between two distant samples still cuts")
    func cutsSparseSegment() {
        // Samples 20mm apart; the eraser crosses the middle and touches neither endpoint.
        let layer = [drawing([(0, 0), (20, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [identity],
                                            path: [CGPoint(x: 10, y: -5), CGPoint(x: 10, y: 5)],
                                            radiusMm: 1)
        #expect(out.drawings.isEmpty) // both samples' only segment is erased
        #expect(out.changedIndices.isEmpty)
    }

    @Test("thickness widens the hit test")
    func thickStrokeErasesOnEdgeTouch() {
        // Centreline is 3mm away; radius 1 alone misses, but baseWidth 5 (half = 2.5) reaches it.
        let thin = [drawing([(0, 0), (10, 0)], baseWidth: 0.5)]
        let thick = [drawing([(0, 0), (10, 0)], baseWidth: 5)]
        let path = [CGPoint(x: 5, y: 3)]
        #expect(AnnotationEraseCore.erase(thin, transforms: [identity], path: path, radiusMm: 1)
            .changedIndices.isEmpty)
        #expect(AnnotationEraseCore.erase(thick, transforms: [identity], path: path, radiusMm: 1)
            .drawings.isEmpty)
    }

    @Test("an unresolved drawing passes through untouched")
    func skipsUnresolved() {
        let layer = [drawing([(0, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [nil],
                                            path: [CGPoint(x: 5, y: 0)], radiusMm: 10)
        #expect(out.drawings.count == 1)
        #expect(out.changedIndices.isEmpty)
    }

    @Test("absent optional channels stay absent, present ones stay aligned")
    func keepsArrayShape() {
        let layer = [drawing([(0, 0), (2, 0), (4, 0), (6, 0), (8, 0), (10, 0)])]
        let out = AnnotationEraseCore.erase(layer, transforms: [identity],
                                            path: [CGPoint(x: 5, y: 0)], radiusMm: 1.2)
        for d in out.drawings {
            let s = decoded(d)
            #expect(s.y.count == s.x.count)
            #expect(s.width.count == s.x.count)
            #expect(s.force.isEmpty)
            #expect(s.azimuth.isEmpty)
            #expect(s.altitude.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationEraseCoreTests
```

Expected: compile failure, `cannot find 'AnnotationEraseCore' in scope`.

- [ ] **Step 3: Implement `AnnotationEraseCore`**

Create `AnnotationEraseCore.swift`. Key points the implementer must not deviate from:

- Segment-based hit test, not sample-based. For each consecutive sample pair, compute the minimum distance between that stroke segment and every eraser segment (segment-to-segment distance; for a single-point path treat it as a degenerate segment). A segment is erased when that distance `<= radiusMm + halfWidth`.
- `halfWidth` for the segment is `max(max(width[i], width[i+1]), placed.baseWidthSp) / 2`, computed **after** `place()`. Per-point `width` is 0 for every Android stroke today, so `baseWidthSp` is what carries thickness.
- A sample survives when at least one of its adjacent segments survives. Runs are maximal contiguous survivor spans; runs shorter than 2 samples are dropped.
- Unchanged drawing → return the original `DrawingAnchor` value, not a re-encoded copy, and do not list it.
- Fragments keep the parent's `kind` (the anchor) and re-encode only the sliced, still-anchor-relative geometry. Slice the **stored** stroke, not the placed one, so no round-trip error is introduced.
- Optional channels (`force`, `azimuth`, `altitude`, `timeMillis`) are sliced only when non-empty; empty stays empty.

```swift
public struct EraseResult: Sendable {
    public let drawings: [DrawingAnchor]
    public let changedIndices: [Int]

    public init(drawings: [DrawingAnchor], changedIndices: [Int]) {
        self.drawings = drawings
        self.changedIndices = changedIndices
    }
}

public enum AnnotationEraseCore {
    public static func erase(
        _ drawings: [DrawingAnchor],
        transforms: [StrokeTransform?],
        path: [CGPoint],
        radiusMm: CGFloat,
    ) -> EraseResult {
        // ... per the rules above
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Same command as Step 2. Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotationEraseCore.swift Packages/Features/Reader/Tests/ReaderTests/AnnotationEraseCoreTests.swift
git commit -m "feat(reader): add the shared erase core"
```

---

## Task 2: Erase wire format and JNI entry point

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift`
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt`

**Interfaces:**
- Consumes: `AnnotationEraseCore.erase` from Task 1.
- Produces: `ReaderAnnotationJNI.erase(drawingsBytes: ByteArray, transformsBytes: ByteArray, requestBytes: ByteArray): ByteArray`, plus the generated Kotlin codecs `EraseRequestWireCodec` and `EraseResultWireCodec`.

- [ ] **Step 1: Add the wire types**

In `AnnotationWire.swift`, following the existing `@WireFormat` declarations in that file:

```swift
/// One eraser gesture sample batch: the centreline in document mm plus the eraser's geometric radius.
@WireFormat
public struct EraseRequestWire: Equatable {
    public let xMm: [Double]
    public let yMm: [Double]
    public let radiusMm: Double
}

/// Result of an erase: the replacement layer plus which of its entries changed geometry.
@WireFormat
public struct EraseResultWire: Equatable {
    public let drawings: [DrawingAnchorWire]
    public let changedIndices: [Int32]
}
```

- [ ] **Step 2: Add the JNI symbol**

In `AnnotationJNISymbols.swift`, mirroring `nativeAnnotationDisplayTransforms`:

```swift
@_cdecl("...") // follow the exact pattern already used in this file
public func nativeAnnotationErase(_ drawings: Data, _ transforms: Data, _ request: Data) -> Data
```

It decodes `[DrawingAnchorWire]`, `[StrokeTransformWire]` and `EraseRequestWire`, maps them onto the core's types, calls `AnnotationEraseCore.erase`, and encodes an `EraseResultWire`. Return empty `Data` on any decode failure — the established "empty means the call failed" convention.

- [ ] **Step 3: Add the Kotlin facade**

In `ReaderAnnotationJNI.kt`, matching the existing methods exactly in style:

```kotlin
/** Cut the layer along an eraser path. Empty result = the call failed; leave the layer alone. */
fun erase(drawingsBytes: ByteArray, transformsBytes: ByteArray, requestBytes: ByteArray): ByteArray {
    val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
    return SwiftJavaJNI.nativeAnnotationErase(
        SwiftData.fromByteArray(drawingsBytes, arena),
        SwiftData.fromByteArray(transformsBytes, arena),
        SwiftData.fromByteArray(requestBytes, arena),
        arena,
    ).toByteArray()
}
```

- [ ] **Step 4: Rebuild the `.so` and the generated bindings**

```bash
Scripts/android-build-reader-libs.sh
```

Expected: `Build of product 'FolinoReaderJNI' complete!` and a staging line for `java-generated`.

- [ ] **Step 5: Verify the symbol is exported and Kotlin compiles**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin
```

Expected: `BUILD SUCCESSFUL`, no unresolved reference to `nativeAnnotationErase`.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/FolinoReaderJNI Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt
git commit -m "feat(reader): bridge the erase core over JNI"
```

---

## Task 3: Tool state and width presets

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationToolState.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ink/AnnotationToolStateTest.kt`

**Interfaces:**
- Produces:
  ```kotlin
  sealed interface AnnotationTool {
      data class Pen(val colorIndex: Int) : AnnotationTool
      data object Eraser : AnnotationTool
  }
  data class AnnotationToolState(
      val selected: AnnotationTool = AnnotationTool.Pen(0),
      val penWidths: List<Float> = AnnotationWidths.PEN_DEFAULTS,
      val eraserWidth: Float = AnnotationWidths.ERASER_PRESETS[1],
  ) {
      val activeWidth: Float
      fun withWidthForSelected(width: Float): AnnotationToolState
  }
  object AnnotationWidths {
      val PEN_PRESETS: List<Float>      // 0.6, 1.2, 2.0, 3.2
      val ERASER_PRESETS: List<Float>   // 2.0, 4.0, 8.0, 14.0
      val PEN_DEFAULTS: List<Float>     // 1.2 x 4
      fun presetIndex(presets: List<Float>, width: Float): Int
  }
  ```

- [ ] **Step 1: Write the failing test**

```kotlin
package com.keynumber.folino.reader.ink

import org.junit.Assert.assertEquals
import org.junit.Test

class AnnotationToolStateTest {
    @Test fun activeWidthFollowsTheSelectedPen() {
        val s = AnnotationToolState(
            selected = AnnotationTool.Pen(2),
            penWidths = listOf(0.6f, 1.2f, 3.2f, 2.0f),
        )
        assertEquals(3.2f, s.activeWidth, 1e-6f)
    }

    @Test fun activeWidthFollowsTheEraser() {
        val s = AnnotationToolState(selected = AnnotationTool.Eraser, eraserWidth = 8f)
        assertEquals(8f, s.activeWidth, 1e-6f)
    }

    @Test fun settingAWidthOnlyTouchesTheSelectedPen() {
        val s = AnnotationToolState(selected = AnnotationTool.Pen(1))
            .withWidthForSelected(3.2f)
        assertEquals(3.2f, s.penWidths[1], 1e-6f)
        assertEquals(AnnotationWidths.PEN_DEFAULTS[0], s.penWidths[0], 1e-6f)
        assertEquals(AnnotationWidths.ERASER_PRESETS[1], s.eraserWidth, 1e-6f)
    }

    @Test fun settingAWidthOnTheEraserLeavesPensAlone() {
        val s = AnnotationToolState(selected = AnnotationTool.Eraser).withWidthForSelected(14f)
        assertEquals(14f, s.eraserWidth, 1e-6f)
        assertEquals(AnnotationWidths.PEN_DEFAULTS, s.penWidths)
    }

    @Test fun presetIndexSnapsToTheNearestPreset() {
        assertEquals(1, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 1.2f))
        assertEquals(3, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 99f))
        assertEquals(0, AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, 0f))
    }

    @Test fun defaultPenWidthMatchesTheShippingWidth() {
        assertEquals(1.2f, AnnotationToolState().activeWidth, 1e-6f)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests '*AnnotationToolStateTest*'
```

Expected: compile failure, unresolved reference `AnnotationToolState`.

- [ ] **Step 3: Implement `AnnotationToolState.kt`**

`presetIndex` returns the index of the nearest preset by absolute difference — it must never throw for an out-of-range stored value, because a persisted width from a future preset table has to degrade gracefully.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationToolState.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ink/AnnotationToolStateTest.kt
git commit -m "feat(reader-android): add annotation tool state and width presets"
```

---

## Task 4: The layer choke point, undo and redo

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/DrawingHistoryTest.kt`

**Interfaces:**
- Produces, on `ReaderViewModel`:
  ```kotlin
  val canUndo: StateFlow<Boolean>
  val canRedo: StateFlow<Boolean>
  fun undoDrawings()
  fun redoDrawings()
  fun beginDrawingGesture()   // snapshots the layer for one undo entry
  private fun applyDrawings(
      pushHistory: Boolean,
      persist: Boolean,
      transform: (List<DrawingAnchorWire>) -> List<DrawingAnchorWire>,
  )
  ```
  Plus an extracted `DrawingHistory` class holding the two stacks so it is unit-testable without a
  view model:
  ```kotlin
  internal class DrawingHistory(private val maxDepth: Int = 30) {
      val canUndo: Boolean
      val canRedo: Boolean
      fun push(previous: List<DrawingAnchorWire>)
      fun undo(current: List<DrawingAnchorWire>): List<DrawingAnchorWire>?
      fun redo(current: List<DrawingAnchorWire>): List<DrawingAnchorWire>?
      fun clear()
  }
  ```

- [ ] **Step 1: Write the failing test for `DrawingHistory`**

Use a plain stand-in list of `DrawingAnchorWire`; if constructing one is awkward, make `DrawingHistory`
generic over the element type (`DrawingHistory<T>`) — it only ever holds and returns whole lists.

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DrawingHistoryTest {
    private fun layer(vararg names: String) = names.toList()

    @Test fun undoReturnsThePreviousLayer() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        assertTrue(h.canUndo)
        assertEquals(layer("a"), h.undo(layer("a", "b")))
    }

    @Test fun redoReturnsTheUndoneLayer() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        assertTrue(h.canRedo)
        assertEquals(layer("a", "b"), h.redo(layer("a")))
    }

    @Test fun aNewMutationClearsRedo() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        h.push(layer("a"))
        assertFalse(h.canRedo)
    }

    @Test fun depthIsCapped() {
        val h = DrawingHistory<String>(maxDepth = 3)
        repeat(10) { h.push(layer("s$it")) }
        var current = layer("now")
        var steps = 0
        while (h.canUndo) { current = h.undo(current)!!; steps++ }
        assertEquals(3, steps)
    }

    @Test fun clearEmptiesBothStacks() {
        val h = DrawingHistory<String>()
        h.push(layer("a"))
        h.undo(layer("a", "b"))
        h.clear()
        assertFalse(h.canUndo)
        assertFalse(h.canRedo)
    }

    @Test fun undoOnAnEmptyStackReturnsNull() {
        assertNull(DrawingHistory<String>().undo(layer("a")))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests '*DrawingHistoryTest*'
```

Expected: unresolved reference `DrawingHistory`.

- [ ] **Step 3: Implement `DrawingHistory` and rewire the view model**

`DrawingHistory` goes in `ReaderViewModel.kt` (it is small and only used there).

Then in `ReaderViewModel`:

```kotlin
private fun applyDrawings(
    pushHistory: Boolean,
    persist: Boolean,
    transform: (List<DrawingAnchorWire>) -> List<DrawingAnchorWire>,
) {
    var previous: List<DrawingAnchorWire>? = null
    val updated = _drawings.updateAndGet { current ->
        previous = current
        transform(current)
    }
    if (pushHistory) previous?.let(history::push)
    if (persist) saveController.drawingsChanged(updated)
    _canUndo.value = history.canUndo
    _canRedo.value = history.canRedo
}
```

Rewrite the existing callers:

- `addDrawing(drawing)` → `applyDrawings(pushHistory = true, persist = true) { it + drawing }`
- `removeDrawing(index)` → `applyDrawings(pushHistory = true, persist = true) { l -> l.filterIndexed { i, _ -> i != index } }`
- The `loadedDrawings` collector → `applyDrawings(pushHistory = false, persist = false) { wires }` and
  `history.clear()`.
- `load(scoreId)` for a different score → `history.clear()`.

`undoDrawings` / `redoDrawings` swap the layer through `history.undo/redo`, persist, and do **not**
push history.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest
```

Expected: `BUILD SUCCESSFUL`, including the pre-existing `AnnotationHandoffQueueTest` and
`PipStaffCountTest`.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/DrawingHistoryTest.kt
git commit -m "feat(reader-android): funnel layer mutations through one choke point with undo/redo"
```

---

## Task 5: Eraser input in the wet overlay

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationWetOverlay.kt`

**Interfaces:**
- Consumes: `AnnotationTool` from Task 3.
- Produces: two new `AnnotationWetOverlay` parameters —
  ```kotlin
  eraserMode: Boolean,
  onEraseGesture: (phase: ErasePhase, pathMm: List<Offset>) -> Unit,
  ```
  where `enum class ErasePhase { BEGIN, MOVE, END }`. `BEGIN` carries the first point, `MOVE` carries
  the points accumulated since the last emission, `END` carries any remainder.

- [ ] **Step 1: Add the eraser branch to the touch listener**

When `eraserMode` is true the listener must not call `startStroke` / `addToStroke` / `finishStroke` at
all. It maps each `MotionEvent` coordinate through `screenToWorld` (the same matrix the pen path uses)
and emits:

- `ACTION_DOWN` → `onEraseGesture(BEGIN, listOf(p))`, and `requestUnbufferedDispatch`.
- `ACTION_MOVE` → accumulate; emit `MOVE` when at least `ERASE_THROTTLE_MS = 50` have passed since the
  last emission, using `event.eventTime` rather than wall-clock so it follows the input timeline.
- `ACTION_UP` → `onEraseGesture(END, remainder)`.
- `ACTION_POINTER_DOWN` → emit `END` with the remainder and return `false`, handing the gesture to the
  parent for pan/zoom. What was already erased stays erased, per the spec.
- `ACTION_CANCEL` → emit `END` with the remainder.

Two-finger palm/stylus handling stays exactly as it is for the pen path; the eraser has no
stylus-always-draws rule.

- [ ] **Step 2: Verify it compiles**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationWetOverlay.kt
git commit -m "feat(reader-android): collect an eraser path in the wet overlay"
```

---

## Task 6: The two-phase erase controller

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationEraseController.kt`

**Interfaces:**
- Consumes: `ReaderAnnotationJNI.erase` (Task 2), `AnnotationCaptureController.capture` (existing),
  `SheetMusicJNI.nativeAnchorReferencePoint` (existing), the wire codecs.
- Produces:
  ```kotlin
  object AnnotationEraseController {
      /// Phase 1: cut the layer along `pathMm`. Fragments inherit the parent anchor. Returns null when
      /// the native call failed (caller leaves the layer untouched).
      fun applyErase(
          drawings: List<DrawingAnchorWire>,
          scoreHandle: Long,
          pathMm: List<Offset>,
          radiusMm: Float,
      ): EraseOutcome?

      /// Phase 2: re-anchor the drawings the gesture changed, so each fragment gets its own anchor.
      fun reanchor(
          drawings: List<DrawingAnchorWire>,
          changedIndices: List<Int>,
          scoreHandle: Long,
      ): List<DrawingAnchorWire>
  }
  data class EraseOutcome(val drawings: List<DrawingAnchorWire>, val changedIndices: List<Int>)
  ```

- [ ] **Step 1: Implement phase 1**

Mirror `AnnotationCaptureController`'s sequencing and its comment discipline. Steps: build
`ResolvedAnchorWire`s for every drawing exactly as `AnnotationDryOverlay.computePlacement` does, call
`SheetMusicJNI.nativeAnchorReferencePoint`, call `ReaderAnnotationJNI.displayTransforms`, then call
`ReaderAnnotationJNI.erase` with the transforms and the request. Empty bytes from any step → return
`null`.

- [ ] **Step 2: Implement phase 2**

For each changed index: decode the drawing's stroke to raw bytes (`decodeInkStroke`), place it into
document-mm using the transform for its **current** anchor, then run the existing four-call capture
pipeline on that document-mm stroke. A fragment whose capture returns empty is dropped — and only that
fragment; the rest of the layer is untouched.

- [ ] **Step 3: Verify it compiles**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin
```

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationEraseController.kt
git commit -m "feat(reader-android): sequence the two-phase erase"
```

---

## Task 7: Toolbar — sized swatches, eraser, undo/redo, width picker

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationToolbar.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationWidthPicker.kt`

**Interfaces:**
- Consumes: `AnnotationToolState`, `AnnotationWidths` (Task 3); `canUndo` / `canRedo` (Task 4).
- Produces: a rewritten `AnnotationToolbar(state, presetColors, canUndo, canRedo, onSelect, onWidthChange, onUndo, onRedo, modifier)`.

- [ ] **Step 1: Rewrite the toolbar row**

Layout order: eraser button, the four colour circles, a spacer, undo, redo.

Each colour swatch is a `Box` with a `CircleShape` background whose diameter maps preset index → dp
via `SWATCH_DIAMETERS_DP = listOf(14, 20, 26, 32)`. The selected swatch draws a ring
(`Modifier.border(2.dp, MaterialTheme.colorScheme.outline, CircleShape)` on a slightly larger
container so the ring never changes the circle's own size).

Click behaviour: tapping an unselected tool selects it; tapping the already-selected tool opens the
width picker anchored to it.

- [ ] **Step 2: Build the width picker**

`AnnotationWidthPicker` is a Material 3 `Popup` (with `PopupProperties(focusable = true)`) showing the
four presets for the active tool as circles at `SWATCH_DIAMETERS_DP`, the current one ringed. Tapping
one calls `onWidthChange(preset)` and dismisses.

- [ ] **Step 3: Verify it compiles**

```bash
Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin
```

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/
git commit -m "feat(reader-android): show pen width in the toolbar and add a width picker"
```

---

## Task 8: Wire it all together in ReaderScreen

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt`

- [ ] **Step 1: Hold tool state in the view model**

Add `toolState: StateFlow<AnnotationToolState>` plus `setAnnotationToolState(state)`, following
`setLayoutOptions` exactly.

- [ ] **Step 2: Replace the hard-coded pen constants**

`ReaderScreen` currently passes `annotationTool = 0` and `ANNOTATION_BASE_WIDTH_SP`. Both become
`toolState`-derived: the brush uses `toolState.activeWidth` and the selected colour; `onStrokeCaptured`
passes the same width as `baseWidthSp`.

- [ ] **Step 3: Wire the eraser gesture**

`AnnotationWetOverlay` gets `eraserMode = toolState.selected is AnnotationTool.Eraser`. The
`onEraseGesture` handler:

- `BEGIN` — call `readerVm.beginDrawingGesture()` so exactly one undo entry covers the drag, and start
  accumulating the path.
- `MOVE` — on `Dispatchers.Default`, run `AnnotationEraseController.applyErase` against the **current**
  layer, then `applyDrawings(pushHistory = false, persist = false) { outcome.drawings }`.
- `END` — run the final `applyErase`, then `AnnotationEraseController.reanchor`, then
  `applyDrawings(pushHistory = false, persist = true) { reanchored }`.

Every `applyDrawings` that is not a plain append calls `inkHandoff.releaseAll()` first, so an undone or
erased stroke cannot linger on the wet layer for `MAX_WET_RETENTION_MS`.

- [ ] **Step 4: Wire undo/redo buttons**

Pass `canUndo` / `canRedo` and the two callbacks into the toolbar. Both callbacks call
`inkHandoff.releaseAll()` before mutating.

- [ ] **Step 5: Build and install on the connected device**

```bash
Android/gradlew -p Android :app:installDebug
adb shell am start -n com.harmolo.folino/com.keynumber.folino.MainActivity
```

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/
git commit -m "feat(reader-android): wire the eraser, width picker and undo into the Reader"
```

---

## Task 9: Persist the pen setup

**Files:**
- Modify: the app module's settings DataStore and `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

- [ ] **Step 1: Add the DataStore keys and flow**

Keys `annotation_pen_width_0..3`, `annotation_eraser_width`, `annotation_selected_tool`, alongside the
existing display-settings keys. Missing keys fall back to `AnnotationToolState()` defaults.

- [ ] **Step 2: Pass it through as props**

`ReaderScreen` gains `annotationToolState: AnnotationToolState` and
`onAnnotationToolStateChange: (AnnotationToolState) -> Unit`, wired in `MainActivity` next to
`displayOptions` / `onDisplayOptionsChange`. `ReaderScreen` pushes into the view model from
`LaunchedEffect(annotationToolState)`. The app module never touches the view model.

- [ ] **Step 3: Verify persistence on device**

Change a pen width and the selected tool, force-stop the app, relaunch, and confirm both survived.

```bash
adb shell am force-stop com.harmolo.folino
adb shell am start -n com.harmolo.folino/com.keynumber.folino.MainActivity
```

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android): persist the annotation pen setup"
```

---

## Task 10: On-device verification

**Files:** none — this task produces evidence, not code.

- [ ] **Step 1: Erase across a stroke and confirm the fragments survive a reflow**

Draw a long stroke across several measures, erase its middle, then change the staff size in Display
settings. Both fragments must stay with the music they were drawn over. This is what proves the phase-2
re-anchor works; with phase 1 alone they would drift together.

- [ ] **Step 2: Confirm no ghost after undo**

Draw a stroke and tap undo within a second of lifting the finger. The ink must disappear immediately,
not two seconds later — that is the `releaseAll()` on the handoff queue.

- [ ] **Step 3: Confirm the eraser does not fight pan/zoom**

With the eraser selected, put a second finger down mid-erase. The gesture must hand off to pan/zoom,
what was erased stays erased, and one undo restores it.

- [ ] **Step 4: Measure erase throughput**

On a dense score, erase with a long drag and watch for stutter. If it stutters, note it — the fix is to
re-place only `changedIndices` in the dry overlay rather than the whole layer, which the spec already
identifies.

- [ ] **Step 5: Tune the presets by eye**

Check all four pen widths and all four eraser widths against real music at the default staff size and
adjust the tables in `AnnotationWidths` if they read badly.

- [ ] **Step 6: Commit any tuning**

```bash
git add -A
git commit -m "fix(reader-android): tune annotation width presets"
```

---

## Self-Review

**Spec coverage:** partial eraser → Tasks 1, 2, 5, 6, 8. Four presets per pen plus eraser → Task 3,
surfaced in Task 7. Re-tap width picker → Task 7. Swatches sized by width → Task 7. Undo/redo → Task 4,
wired in Task 8. Persistence → Task 9. Two-phase anchoring → Tasks 6 and 8, verified in Task 10 Step 1.
Handoff-queue release → Task 8 Steps 3 and 4, verified in Task 10 Step 2. Gesture interruption → Task 5
Step 1, verified in Task 10 Step 3. Throughput risk → Task 10 Step 4.

**Type consistency:** `AnnotationToolState.activeWidth` and `withWidthForSelected` are used in Tasks 7
and 8 as defined in Task 3. `EraseOutcome.changedIndices` is `List<Int>` in Task 6 and consumed as such
in Task 8. `ReaderAnnotationJNI.erase` takes three `ByteArray`s in Task 2 and is called that way in Task
6. `applyDrawings(pushHistory, persist, transform)` keeps the same signature in Tasks 4 and 8.

**Known gap accepted deliberately:** there is no automated test for the two-phase anchoring — it needs a
live ssm layout, which the Kotlin unit-test target cannot provide. Task 10 Step 1 is the check.

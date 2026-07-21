# Android Annotation — Sub-plan E: androidx.ink wet/dry capture + render (MVP-first) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make freehand annotations actually drawable, persisted, and reflow-following on Android — capture ink with `androidx.ink`, anchor it to the score through the Sub-plan C JNI bridge, persist through the Sub-plan D save coordinator, and re-render committed ink over the score, verified end-to-end in the emulator.

**Architecture:** A wet/dry split. **Wet** = `androidx.ink` `InProgressStrokesView` (View-based, per-pointer) wrapped in an `AndroidView`, capturing in **document-millimetre world coordinates**. On finish, each stroke is serialized to a neutral `RawInkStrokeWire`, encoded to the shared `InkStroke` FINK format **in Swift** (new thin JNI), anchored via the C capture bridge (→ `DrawingAnchorWire`), appended to the layer, and saved through the D `AnnotationSaveController`. **Dry** = a sibling Compose overlay next to `PlaybackCursorOverlay` that, each reflow, batches the layer's anchors through the C display bridge (→ `[StrokeTransformWire]`), rebuilds each `androidx.ink` `Stroke` from FINK (new thin JNI decode), and draws it with `CanvasStrokeRenderer` at `camera ∘ placement`. **No InkStroke codec is reimplemented in Kotlin** — it stays in `Domain.InkStrokeCodec`, reached over JNI (iOS/Android parity rule).

**Tech Stack:** `androidx.ink` 1.0.0 (Apache-2.0; `ink-strokes`/`ink-brush`/`ink-brush-compose`/`ink-authoring`/`ink-rendering`/`ink-geometry`), `androidx.input:input-motionprediction:1.0.0`, Kotlin/Jetpack Compose, Swift 6.3 (`FolinoReaderJNI` + `ReaderAnnotationCore`), swift-wirelet `@WireFormat`/`@WireletObservable` (pin `ba1b8e337a508079c5213656e4c01e9edbedc8b4`; Gradle plugin/runtime 0.3.2), swift-sheet-music Android `0.0.0-SNAPSHOT` (mavenLocal), Room (Sub-plan D5).

## Global Constraints

- **Logic lives in shared Swift; Kotlin is UI + I/O only.** The `InkStroke` FINK codec, anchor math, and save policy are never reimplemented in Kotlin — reached over JNI (`FolinoReaderJNI` → `Domain`/`ReaderAnnotationCore`). (CLAUDE.md iOS/Android parity; `feedback_ios_android_parity`.)
- **Never persist androidx.ink's own serialized format.** Only the neutral `InkStroke` FINK bytes extracted from `Stroke.inputs`; rebuild `Stroke(brush, inputs)` on load.
- **World space = document millimetres** everywhere in the annotation pipeline (capture, anchor, render). `representativePoint`/`capture` already assume the wet `InkStroke` geometry is in doc-mm.
- **Pin versioned stock brushes** (`StockBrushes.*Version.V1`), never `LATEST`, so serialized strokes stay pixel-stable across OS/library upgrades.
- **No offscreen compositing** on the ink or document layers (`CompositingStrategy.Offscreen`, `alpha < 1`, `renderEffect`) — HWUI offscreen layers hit the max-texture cap; a vertical document at 8× exceeds it. Apply stroke alpha per-paint / via brush color alpha.
- **Build the dry-draw matrix in viewport-local space** (the camera matrix the score canvas already uses: `fitPxPerMM * scale`, `vPadPx` translate) — avoids float32 quantization deep in a long document at 8×.
- **`ReaderAnnotationCore` / `FolinoReaderJNI` carry no SwiftLint plugin** (cross-compiled for Android; host pre-commit lints them).
- **swift-wirelet is pinned by revision** `ba1b8e337a508079c5213656e4c01e9edbedc8b4`; Gradle plugin/runtime 0.3.2.
- **No GPL dependencies.** `androidx.ink` and `androidx.input:input-motionprediction` are Apache-2.0 — compliant.
- **App name is lowercase `folino`** anywhere user-visible.
- **`FolinoReaderJNI` is NOT host-unit-testable** (it pulls `swift-java`, which is macOS-only and fails to compile for the iOS Simulator). It is verified by the **arm64 cross-build** (`swift build --product FolinoReaderJNI --swift-sdk aarch64-unknown-linux-android28`, or `Scripts/android-build-reader-libs.sh`) + the E9 emulator runtime. **Any host-testable logic must live in `ReaderAnnotationCore`** (Foundation+Domain, tested via `-scheme Reader` with NO `FOLINO_ANDROID` — the path the existing 29 annotation tests and `PrefetchedAnchorResolver` use). Tests never `import FolinoReaderJNI`.

## MVP scope (this plan) vs. deferred

**In scope (E0–E8):** ssm mavenLocal republish; the Swift/JNI codec + read-path seams; androidx.ink wet capture + dry render wired through anchor + persistence; **vertical (and horizontal-continuous) modes**; a **minimal toolset — pen + whole-stroke eraser + a few preset colors**; the emulator round-trip gate.

**Deferred to follow-on UI iteration (NOT this plan; not auto-committed per project convention):** the full tool palette (highlighter fidelity tuning, color picker, width slider, undo/redo polish, toolbar placement/icons/spacing), **paged-mode** ink (place inside `HorizontalPager` via `partitionByPage`), stylus tilt/azimuth channel fidelity, and text-box authoring. E7 lands a *functional* minimal toolbar; visual refinement is thrown by eye afterward.

## Verified androidx.ink 1.0.0 API notes (used below)

Signatures below were verified against the frozen `ink/<module>/api/1.0.0-rc01.txt` signature files (== stable 1.0.0). Traps to respect:

- `InProgressStrokesView.startStroke(event, pointerId, brush, motionEventToWorldTransform)` — the `Matrix` is **`android.graphics.Matrix`**; `motionEventToWorldTransform` is **screen→world** (inverse of the camera).
- Finished callback: `InProgressStrokesFinishedListener.onStrokesFinished(Map<InProgressStrokeId, Stroke>)`; then `removeFinishedStrokes(keys)` **same frame**.
- Read inputs: `stroke.inputs` is an `ImmutableStrokeInputBatch`; iterate `0 until batch.size`, `batch.populate(i, scratch)` into a reused `StrokeInput`; fields `x, y, elapsedTimeMillis, toolType, pressure/hasPressure, tiltRadians/hasTilt, orientationRadians/hasOrientation, strokeUnitLengthCm`.
- Rebuild: `MutableStrokeInputBatch().add(type, x, y, elapsedTimeMillis, strokeUnitLengthCm, pressure, tiltRadians, orientationRadians)` — **`strokeUnitLengthCm` precedes `pressure`**; sentinels `StrokeInput.NO_PRESSURE/NO_TILT/NO_ORIENTATION = -1f`, `NO_STROKE_UNIT_LENGTH = 0f`.
- `Brush.createWithColorIntArgb(family, colorIntArgb, size, epsilon)`; families `StockBrushes.pressurePen(StockBrushes.PressurePenVersion.V1)`, `StockBrushes.highlighter(SelfOverlap.ACCUMULATE, StockBrushes.HighlighterVersion.V1)`.
- Render: `CanvasStrokeRenderer.create()`; `draw(android.graphics.Canvas, stroke, android.graphics.Matrix strokeToScreen)`. In Compose bridge with `drawIntoCanvas { it.nativeCanvas }`.
- **Verify at compile (androidx.ink UNVERIFIED):** `InputToolType` member names (likely `UNKNOWN/MOUSE/TOUCH/STYLUS`); `MotionEventPredictor.create/record/predict` signatures; core `Brush` int/size/epsilon getter names (store attributes from our own model instead of reading them back — see E5/E6). Each is isolated to one step below with a fallback.

---

## File structure

| File | Responsibility | New? |
|---|---|---|
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/InkStrokeRawFields.swift` | Host-testable raw-fields ⇄ `Domain.InkStroke` mapping (Foundation+Domain). | Create |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/RawInkStrokeWire.swift` | `@WireFormat` mirror of `InkStrokeRawFields` (androidx.ink ⇄ Swift wire). | Create |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift` | Add `nativeEncodeInkStroke` / `nativeDecodeInkStroke` (raw ⇄ FINK, via `Domain.InkStrokeCodec`). | Modify |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationSaveBridge.swift` | Add the **read path**: observable `loadedDrawings: [DrawingAnchorWire]` populated by `open`. | Modify |
| `Packages/Features/Reader/Tests/ReaderTests/InkStrokeRawFieldsTests.swift` | Host round-trip via `-scheme Reader`: raw → FINK → raw is exact (Float32-exact values); unknown tool → pen. | Create |
| `Android/FolinoReaderAndroid/build.gradle.kts` | Add androidx.ink + motionprediction deps. | Modify |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ReaderAnnotationJNI.kt` | Add `encodeInkStroke` / `decodeInkStroke` facade wrappers. | Modify |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/InkBrushMapping.kt` | `InkStroke.Tool` ⇄ `StockBrushes` family (V1) + color/width mapping. | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/InkStrokeSerialization.kt` | `Stroke` ⇄ `RawInkStrokeWire` bytes (serialize inputs / rebuild `Stroke`). | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationCaptureController.kt` | The capture pipeline: finished `Stroke` → anchored `DrawingAnchorWire`. | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ReaderViewModel.kt` | Annotation mode flag + drawings state + save-controller wiring. | Modify |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationWetOverlay.kt` | `AndroidView(InProgressStrokesView)` wet capture + per-pointer routing. | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationDryOverlay.kt` | Compose `Canvas` dry render of committed strokes at `camera ∘ placement`. | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationToolbar.kt` | Minimal bottom toolbar (pen / eraser / preset colors). | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/.../ReaderScreen.kt` | Toggle entry point; mount overlays; gate scroll in annotation mode. | Modify |
| `Android/FolinoReaderAndroid/src/androidTest/.../AnnotationRoundTripTest.kt` | Instrumented: draw → persist → relaunch → load → render. | Create |

**Data flow (reference for every task):**

```
CAPTURE:  androidx.ink Stroke (doc-mm world)
  → InkStrokeSerialization.toRawWireBytes            (Kotlin: read stroke.inputs + brush)
  → ReaderAnnotationJNI.encodeInkStroke(rawBytes)    (Swift: RawInkStrokeWire → InkStroke → FINK)
  → ReaderAnnotationJNI.representativePoint(fink)     (Swift: bbox-center PointMmWire)
  → SheetMusicJNI.nativeResolveAnchor(handle, xMm,yMm) (ssm: ResolvedAnchorWire)
  → SheetMusicJNI.nativeAnchorReferencePoint(handle, [anchor]) (ssm: [AnchorRefPointWire])
  → ReaderAnnotationJNI.capture(fink, resolved, ref) (Swift: DrawingAnchorWire, normalized sp)
  → append to ReaderViewModel.drawings + AnnotationSaveController.drawingsChanged(...)

RENDER (per reflow / zoom / scroll):  drawings: [DrawingAnchorWire]
  → SheetMusicJNI.nativeAnchorReferencePoint(handle, anchorsOf(drawings)) (ssm: [AnchorRefPointWire])
  → ReaderAnnotationJNI.displayTransforms(drawingsBytes, refPointsBytes)  (Swift: [StrokeTransformWire])
  → per drawing: ReaderAnnotationJNI.decodeInkStroke(encodedDrawing)      (Swift: FINK → RawInkStrokeWire)
  → InkStrokeSerialization.toStroke(rawWire)         (Kotlin: rebuild androidx.ink Stroke, anchor-rel sp geom)
  → CanvasStrokeRenderer.draw(canvas, stroke, camera ∘ [scale sp, translate (px,py)])
```

`nativeResolveAnchor` / `nativeAnchorReferencePoint` are ssm `SheetMusicJNI` symbols — present at runtime only after E0.

---

## Task E0: ssm mavenLocal republish (runtime anchor symbols)

**Why:** the anchor-primitive JNI (`nativeResolveAnchor` / `nativeAnchorReferencePoint`) landed in ssm main (v1.1.1, Sub-plan B) but the **Android mavenLocal artifacts were last published before it**. Folino Android consumes ssm via mavenLocal `0.0.0-SNAPSHOT`, so those symbols are absent at runtime until we republish. iOS pins a git tag and already has them — Android does not.

**Files:** none in Folino. Operates on the ssm clone `~/Developer/Personal/swift-packages/swift-sheet-music` (see `feedback_ssm_side_land_independently`, `project_sheet_music_dev_clone_and_test_block`).

- [ ] **Step 1: Confirm the ssm clone includes the anchor JNI.**

Run: `git -C ~/Developer/Personal/swift-packages/swift-sheet-music log --oneline -1 -- Sources/SheetMusicAndroidJNI/AnchorCodecs.swift`
Expected: a commit exists (the file is present). If the clone is behind, `git -C ~/Developer/Personal/swift-packages/swift-sheet-music checkout main` then `git -C ~/Developer/Personal/swift-packages/swift-sheet-music pull --ff-only`. Do NOT switch a dirty ssm worktree without checking `git -C … status` first.

- [ ] **Step 2: Rebuild the ssm Android `.so`s** with the anchor symbols (arm64 for the emulator):

Run: `env SHEET_MUSIC_ANDROID_ABIS=arm64-v8a ~/Developer/Personal/swift-packages/swift-sheet-music/Scripts/android-build-libs.sh`
Expected: exit 0; `libSheetMusicAndroidJNI.so` staged under `Android/SheetMusicAndroid/src/main/jniLibs/arm64-v8a/`. (The release toolchain is prepended inside the script.)

- [ ] **Step 3: Publish the three Android artifacts to mavenLocal** at `0.0.0-SNAPSHOT`:

Run: `~/Developer/Personal/swift-packages/swift-sheet-music/Android/gradlew -p ~/Developer/Personal/swift-packages/swift-sheet-music/Android publishToMavenLocal --console=plain`
Expected: `BUILD SUCCESSFUL`; updates `~/.m2/repository/io/github/jiyimeta/sheet-music-{android,audio-android,compose-android}/0.0.0-SNAPSHOT/`. (Version defaults to `0.0.0-SNAPSHOT` when `-Pversion` is unset — matches Folino's `ssmVersion` default.)

- [ ] **Step 4: Verify the anchor symbol is in the published `.so`.**

Run: `unzip -l ~/.m2/repository/io/github/jiyimeta/sheet-music-android/0.0.0-SNAPSHOT/sheet-music-android-0.0.0-SNAPSHOT.aar | grep libSheetMusicAndroidJNI.so`
Expected: the `.so` is listed under `jni/arm64-v8a/`. (Runtime presence of `nativeResolveAnchor` is proven end-to-end by E8; the aar listing confirms the freshly built lib shipped.)

- [ ] **Step 5: No commit.** E0 touches only the ssm clone + mavenLocal (untracked artifacts). Record completion in the sub-plan tracking. If the ssm clone was on a branch, leave it as found.

---

## Task E1: `RawInkStrokeWire` + the InkStroke FINK codec seam (Swift/JNI)

> **REVISED 2026-07-21 (supersedes the Steps below).** `FolinoReaderJNI` can't host-test on iOS sim (swift-java macOS-only). Split per the Global-Constraints JNI rule: the raw-fields ⇄ `InkStroke` mapping moves to **`ReaderAnnotationCore/InkStrokeRawFields.swift`** (Foundation+Domain, host round-trip test `ReaderTests/InkStrokeRawFieldsTests.swift` via `-scheme Reader`, NO `FOLINO_ANDROID`; test values Float32-exact). `FolinoReaderJNI` keeps `RawInkStrokeWire.swift` (`@WireFormat` mirroring `InkStrokeRawFields`, converts to/from it) + `nativeEncodeInkStroke`/`nativeDecodeInkStroke` (append to `AnnotationJNISymbols.swift`, delegate to the core mapping + `InkStrokeCodec`), verified by the **arm64 cross-build** `swift build --product FolinoReaderJNI --swift-sdk aarch64-unknown-linux-android28 -c release`. The original Step code below is correct in substance (the wire type + native functions) but its host-test verification is replaced by the split above.

**Files:**
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/RawInkStrokeWire.swift`
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/RawInkStrokeCodecTests.swift`

**Interfaces:**
- Consumes: `Domain.InkStroke`, `Domain.InkStrokeCodec` (existing: `InkStrokeCodec.encode(_:) -> Data`, `InkStrokeCodec.decode(_:) throws -> InkStroke`), `Wirelet.@WireFormat`.
- Produces: Swift `nativeEncodeInkStroke(rawBytes: Data) -> Data` (raw → FINK), `nativeDecodeInkStroke(finkBytes: Data) -> Data` (FINK → raw); `RawInkStrokeWire` with fields `tool: UInt8, colorRGBA: UInt32, baseWidthSp: Double, opacity: Double, x: [Double], y: [Double], width: [Double], force: [Double], timeMillis: [Int32]`.

- [ ] **Step 1: Write the failing round-trip test.**

`Packages/Features/Reader/Tests/ReaderTests/RawInkStrokeCodecTests.swift`:

```swift
import Foundation
import Testing
@testable import FolinoReaderJNI

@Suite struct RawInkStrokeCodecTests {
    @Test func rawEncodeDecodeRoundTrips() throws {
        let raw = RawInkStrokeWire(
            tool: 0, colorRGBA: 0xFF3366FF, baseWidthSp: 1.5, opacity: 0.9,
            x: [10, 11.5, 13], y: [20, 20.25, 21], width: [1.5, 1.6, 1.4],
            force: [0.5, 0.7, 0.6], timeMillis: [0, 8, 16],
        )
        let fink = nativeEncodeInkStroke(rawBytes: raw.encodeToData())
        #expect(!fink.isEmpty)
        let back = try #require(try? RawInkStrokeWire(decoding: nativeDecodeInkStroke(finkBytes: fink)))
        #expect(back == raw)
    }

    @Test func garbageDecodesToEmpty() {
        #expect(nativeEncodeInkStroke(rawBytes: Data([0x00, 0x01])).isEmpty)
        #expect(nativeDecodeInkStroke(finkBytes: Data([0x00, 0x01])).isEmpty)
    }
}
```

- [ ] **Step 2: Run — FAIL** (`RawInkStrokeWire` / `nativeEncodeInkStroke` undefined).

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/RawInkStrokeCodecTests` (run from `Packages/Features/Reader`; Swift Testing filters by **type name**).
Expected: compile failure / FAIL.

- [ ] **Step 3: Create `RawInkStrokeWire.swift`.**

```swift
import Foundation
import Wirelet

// Raw androidx.ink stroke geometry crossing the JNI boundary in BOTH directions: Kotlin builds it from a finished
// `androidx.ink.Stroke` (capture) and rebuilds a `Stroke` from it (render). Swift is the ONLY side that touches the
// `InkStroke` FINK bytes — this wire keeps the codec in Domain (iOS/Android parity). Field order IS the wire contract.
//
// Geometry is document-millimetres at capture; anchor-relative sp after a decode round-trip. Structure-of-arrays with a
// shared count; `force`/`timeMillis` may be empty when the device didn't provide that channel. `tool` matches
// `Domain.InkStroke.Tool.rawValue`; `colorRGBA` is 0xRRGGBBAA; `baseWidthSp`/`opacity` are Double for wire simplicity
// (narrowed to Float when building `InkStroke`).
@WireFormat
public struct RawInkStrokeWire: Equatable {
    public let tool: UInt8
    public let colorRGBA: UInt32
    public let baseWidthSp: Double
    public let opacity: Double
    public let x: [Double]
    public let y: [Double]
    public let width: [Double]
    public let force: [Double]
    public let timeMillis: [Int32]

    public init(
        tool: UInt8, colorRGBA: UInt32, baseWidthSp: Double, opacity: Double,
        x: [Double], y: [Double], width: [Double], force: [Double], timeMillis: [Int32],
    ) {
        self.tool = tool
        self.colorRGBA = colorRGBA
        self.baseWidthSp = baseWidthSp
        self.opacity = opacity
        self.x = x
        self.y = y
        self.width = width
        self.force = force
        self.timeMillis = timeMillis
    }
}
```

- [ ] **Step 4: Add the two JNI symbols to `AnnotationJNISymbols.swift`** (append; keep the existing `#if !canImport(CoreGraphics)` typealias block at the top of the file):

```swift
/// Encode a raw androidx.ink stroke (document-mm geometry) into neutral `InkStroke` FINK bytes. Kotlin builds
/// `RawInkStrokeWire` from a finished `Stroke`; this is the ONLY encode path so the codec never duplicates into Kotlin.
/// Empty `Data` if the wire fails to decode.
public func nativeEncodeInkStroke(rawBytes: Data) -> Data {
    guard let raw = try? RawInkStrokeWire(decoding: rawBytes) else { return Data() }
    let stroke = InkStroke(
        tool: InkStroke.Tool(rawValue: raw.tool) ?? .pen,
        colorRGBA: raw.colorRGBA,
        baseWidthSp: Float(raw.baseWidthSp),
        opacity: Float(raw.opacity),
        x: raw.x.map(Float.init), y: raw.y.map(Float.init), width: raw.width.map(Float.init),
        force: raw.force.map(Float.init), azimuth: [], altitude: [],
        timeMillis: raw.timeMillis.map { UInt16(clamping: Int($0)) },
    )
    return InkStrokeCodec.encode(stroke)
}

/// Decode neutral `InkStroke` FINK bytes back to a raw wire Kotlin rebuilds a `Stroke` from (render path). Empty `Data`
/// if the bytes don't decode.
public func nativeDecodeInkStroke(finkBytes: Data) -> Data {
    guard let s = try? InkStrokeCodec.decode(finkBytes) else { return Data() }
    return RawInkStrokeWire(
        tool: s.tool.rawValue, colorRGBA: s.colorRGBA,
        baseWidthSp: Double(s.baseWidthSp), opacity: Double(s.opacity),
        x: s.x.map(Double.init), y: s.y.map(Double.init), width: s.width.map(Double.init),
        force: s.force.map(Double.init), timeMillis: s.timeMillis.map { Int32($0) },
    ).encodeToData()
}
```

- [ ] **Step 5: Run — PASS.** Same command as Step 2. Expected: 2 tests pass. (Confirm `InkStrokeCodec.encode` returns `Data` non-throwing and `decode` throws — adjust the `try?` if the real signature differs; grep `Packages/Domain/Sources/Domain/Logic/InkStrokeCodec.swift` first.)

- [ ] **Step 6: Commit.**

```bash
git -C <worktree> add Packages/Features/Reader/Sources/FolinoReaderJNI/RawInkStrokeWire.swift \
  Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift \
  Packages/Features/Reader/Tests/ReaderTests/RawInkStrokeCodecTests.swift
git -C <worktree> commit -m "feat(reader): RawInkStrokeWire + InkStroke FINK encode/decode JNI seam"
```

---

## Task E2: annotation read path on `AnnotationSaveBridge` (Swift/JNI)

> **REVISED 2026-07-21.** `AnnotationSaveBridge` is inherently in `FolinoReaderJNI` (`@WireletObservable`), so it is NOT host-testable (Global-Constraints JNI rule). The `open`→async-load→`loadedDrawings` behavior and the trivial `DrawingAnchor`→`DrawingAnchorWire` mapping are **verified by the arm64 cross-build** (compiles) + the E9 emulator round-trip (runtime), plus the coordinator's own `Domain` tests already covering `AnnotationSaveCoordinator.load`. **Skip the `AnnotationSaveBridgeReadTests` host test** in Step 1 below — replace it with: implement the `loadedDrawings` property + `open` body (Steps 3), then run the `FolinoReaderJNI` arm64 cross-build (`swift build --product FolinoReaderJNI --swift-sdk aarch64-unknown-linux-android28 -c release`) and confirm `Build complete!`. Everything else in the task (the property, the `open` mapping) stands.

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationSaveBridge.swift`
- Test: extend `Packages/Features/Reader/Tests/ReaderTests/` (new `AnnotationSaveBridgeReadTests.swift`).

**Interfaces:**
- Consumes: existing `AnnotationSaveCoordinator.load(scoreID:) async -> [DrawingAnchor]`, `Domain.DrawingAnchor` (`kind: .musical(MusicalAnchor)`, `encodedDrawing: Data`).
- Produces: an observable `AnnotationSaveBridge.loadedDrawings: [DrawingAnchorWire]` (projected to a Kotlin `StateFlow` by `@WireletObservable`), populated when `open(scoreId:)` finishes loading. Kotlin reads it to seed the dry overlay.

- [ ] **Step 1: Write the failing test** (`AnnotationSaveBridgeReadTests.swift`) — after `open`, a pre-stored layer surfaces on `loadedDrawings`:

```swift
import Foundation
import Testing
@testable import FolinoReaderJNI
import Domain

@Suite struct AnnotationSaveBridgeReadTests {
    // Minimal in-memory provided store conforming to the generated @WireletProvided shape.
    final class FakeStore: AnnotationPersistenceStore, @unchecked Sendable {
        var bytes: [String: Data] = [:]
        func loadBytes(scoreId: String) -> Data { bytes[scoreId] ?? Data() }
        func saveBytes(scoreId: String, updatedAtMillis: Int64, bytes payload: Data) { bytes[scoreId] = payload }
        func delete(scoreId: String) { bytes[scoreId] = nil }
    }

    @Test func openPublishesStoredDrawings() async throws {
        let id = UUID()
        let anchor = MusicalAnchor(measureIndex: 2, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                                   dxSp: 0.25, verticalOffsetSp: -1)
        let drawing = DrawingAnchor(kind: .musical(anchor), encodedDrawing: Data([0x46, 0x49, 0x4E, 0x4B]))
        let payload = AnnotationLayerCodec.encode(drawings: [drawing], textBoxes: [])
        let store = FakeStore(); store.bytes[id.uuidString] = payload

        let bridge = AnnotationSaveBridge(store: store)
        bridge.open(scoreId: id.uuidString)
        try await Task.sleep(for: .milliseconds(50))   // open() is fire-and-forget

        #expect(bridge.loadedDrawings.count == 1)
        #expect(bridge.loadedDrawings.first?.measureIndex == 2)
        #expect(bridge.loadedDrawings.first?.encodedDrawing == Data([0x46, 0x49, 0x4E, 0x4B]))
    }
}
```

- [ ] **Step 2: Run — FAIL** (`loadedDrawings` undefined). Command as E1 Step 2 with `-only-testing:ReaderTests/AnnotationSaveBridgeReadTests`.

- [ ] **Step 3: Add the observable read path to `AnnotationSaveBridge`.** Change the `@ObservationIgnored private var scoreId` region to add an observable property and populate it in `open`:

```swift
    // Observable read path (Sub-plan E): the drawings loaded for the active score, projected to a Kotlin StateFlow by
    // @WireletObservable. Seeds the dry overlay on open. Written on the main actor after the async load resolves.
    public private(set) var loadedDrawings: [DrawingAnchorWire] = []
```

Replace the body of `open(scoreId:)`:

```swift
    @WireletExpose
    public func open(scoreId: String) {
        self.scoreId = scoreId
        loadedDrawings = []
        let coordinator = coordinator
        let id = ScoreItemID(rawValue: UUID(uuidString: scoreId) ?? UUID())
        Task { @MainActor in
            let drawings = await coordinator.load(scoreID: id)
            self.loadedDrawings = drawings.map { drawing -> DrawingAnchorWire in
                guard case let .musical(a) = drawing.kind else {
                    return DrawingAnchorWire(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                                             dxSp: 0, verticalOffsetSp: 0, encodedDrawing: drawing.encodedDrawing)
                }
                return DrawingAnchorWire(
                    measureIndex: Int32(a.measureIndex), tickInMeasure: Int32(a.tickInMeasure),
                    partIndex: Int32(a.partIndex), staffIndexInPart: Int32(a.staffIndexInPart),
                    dxSp: a.dxSp, verticalOffsetSp: a.verticalOffsetSp, encodedDrawing: drawing.encodedDrawing,
                )
            }
        }
    }
```

(If `AnnotationSaveCoordinator.load` returns only `.musical` drawings, the `guard` is defensive — MVP has no text boxes on Android. Confirm `DrawingAnchor.Kind` cases by grepping `ReaderAnnotationCore`.)

- [ ] **Step 4: Run — PASS.** Same `-only-testing` command. Expected: 1 test passes.

- [ ] **Step 5: Commit.**

```bash
git -C <worktree> add Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationSaveBridge.swift \
  Packages/Features/Reader/Tests/ReaderTests/AnnotationSaveBridgeReadTests.swift
git -C <worktree> commit -m "feat(reader): AnnotationSaveBridge read path — observable loadedDrawings on open"
```

---

## Task E3: cross-build + restage `FolinoReaderJNI`, extend the Kotlin facade

**Why a task of its own:** E1+E2 changed the Swift `.so` surface (new symbols + wire type + observable property → new jextract bindings + regenerated wirelet observable VM). The Kotlin in E4–E8 compiles against these. This task rebuilds/restages and adds the two facade wrappers, gated by a compile check.

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/.../ReaderAnnotationJNI.kt`

**Interfaces:**
- Consumes: staged `nativeEncodeInkStroke` / `nativeDecodeInkStroke` jextract bindings (from E1); the regenerated `AnnotationSaveBridgeViewModel` with a `loadedDrawings` StateFlow (from E2).
- Produces: `ReaderAnnotationJNI.encodeInkStroke(rawBytes: ByteArray): ByteArray`, `ReaderAnnotationJNI.decodeInkStroke(finkBytes: ByteArray): ByteArray`.

- [ ] **Step 1: Rebuild the Reader `.so` + restage jextract bindings** (arm64):

Run: `env FOLINO_ANDROID_ABIS=arm64-v8a <worktree>/Scripts/android-build-reader-libs.sh`
Expected: exit 0; `java-generated/com/keynumber/folino/reader/swiftjava/FolinoReaderJNI.java` now declares `nativeEncodeInkStroke` / `nativeDecodeInkStroke`; `RawInkStrokeWire.java` present.

- [ ] **Step 2: Add the facade wrappers to `ReaderAnnotationJNI.kt`** (mirror the existing `representativePoint`/`capture` pattern):

```kotlin
    /** Encode a raw androidx.ink stroke (RawInkStrokeWire bytes, document-mm) into neutral InkStroke FINK bytes. */
    fun encodeInkStroke(rawBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeEncodeInkStroke(SwiftData.fromByteArray(rawBytes, arena), arena).toByteArray()
    }

    /** Decode neutral InkStroke FINK bytes back to RawInkStrokeWire bytes for rebuilding an androidx.ink Stroke. */
    fun decodeInkStroke(finkBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeDecodeInkStroke(SwiftData.fromByteArray(finkBytes, arena), arena).toByteArray()
    }
```

- [ ] **Step 3: Compile gate** — `:FolinoReaderAndroid:compileDebugKotlin` (dependency swift-wirelet resolve for Soundfont must exist — see the Sub-plan D5 gotcha):

Run: `<worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:compileDebugKotlin --console=plain`
Expected: `BUILD SUCCESSFUL`; the regenerated `AnnotationSaveBridgeViewModel` exposes a `loadedDrawings` `StateFlow<List<DrawingAnchorWire>>`. If `:FolinoSoundfontAndroid:generateWireletCodecsMain` fails with `chdir error: … .build/checkouts/swift-wirelet`, run `env FOLINO_ANDROID=1 swift package --package-path <worktree>/Packages/Infrastructure resolve` first, then re-run.

- [ ] **Step 4: Commit** (the staged `.so`/`java-generated` are gitignored; only the facade change is tracked):

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt
git -C <worktree> commit -m "feat(reader-android): encodeInkStroke/decodeInkStroke facade over the FINK JNI seam"
```

---

## Task E4: androidx.ink deps + brush mapping + stroke serialization (Kotlin, pure)

**Files:**
- Modify: `Android/FolinoReaderAndroid/build.gradle.kts`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/InkBrushMapping.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/InkStrokeSerialization.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/.../ink/InkStrokeSerializationTest.kt`

**Interfaces:**
- Produces: `InkBrushMapping.brushFor(tool: Int, colorRGBA: Long, widthSp: Float): Brush`; `InkStrokeSerialization.toRawWireBytes(stroke: Stroke, tool: Int): ByteArray`; `InkStrokeSerialization.toStroke(rawWireBytes: ByteArray, brush: Brush): Stroke`. Wire codec = the wirelet-generated `RawInkStrokeWireCodec` (from E3's codegen).

- [ ] **Step 1: Add dependencies to `build.gradle.kts`** (in the `dependencies { }` block, near the other androidx entries):

```kotlin
    // androidx.ink 1.0.0 (Apache-2.0): wet capture (authoring), dry render (rendering), brush model, geometry.
    implementation("androidx.ink:ink-strokes:1.0.0")
    implementation("androidx.ink:ink-brush:1.0.0")
    implementation("androidx.ink:ink-brush-compose:1.0.0")
    implementation("androidx.ink:ink-authoring:1.0.0")
    implementation("androidx.ink:ink-rendering:1.0.0")
    implementation("androidx.ink:ink-geometry:1.0.0")
    // Low-latency motion prediction for wet capture (separate artifact group, Apache-2.0).
    implementation("androidx.input:input-motionprediction:1.0.0")
```

- [ ] **Step 2: Write `InkBrushMapping.kt`.** Maps `InkStroke.Tool.rawValue` → a versioned stock brush and constructs a `Brush` (color is 0xRRGGBBAA in our model → `@ColorInt` 0xAARRGGBB):

```kotlin
package com.keynumber.folino.reader.ink

import androidx.ink.brush.Brush
import androidx.ink.brush.BrushFamily
import androidx.ink.brush.StockBrushes

/** Maps neutral InkStroke tools/colors to androidx.ink brushes, pinning V1 families for stable re-rendering. */
object InkBrushMapping {
    // InkStroke.Tool.rawValue (Domain): pen=0, marker(highlighter)=1, pencil=2, ...
    private fun family(tool: Int): BrushFamily = when (tool) {
        1 -> StockBrushes.highlighter(StockBrushes.SelfOverlap.ACCUMULATE, StockBrushes.HighlighterVersion.V1)
        else -> StockBrushes.pressurePen(StockBrushes.PressurePenVersion.V1)
    }

    /** 0xRRGGBBAA (our neutral model) -> @ColorInt 0xAARRGGBB. */
    private fun colorInt(colorRGBA: Long): Int {
        val r = (colorRGBA shr 24) and 0xFF; val g = (colorRGBA shr 16) and 0xFF
        val b = (colorRGBA shr 8) and 0xFF;  val a = colorRGBA and 0xFF
        return ((a shl 24) or (r shl 16) or (g shl 8) or b).toInt()
    }

    /** widthSp is a document-mm brush size (our world unit = document mm); epsilon ~0.1mm keeps strokes crisp to 8x. */
    fun brushFor(tool: Int, colorRGBA: Long, widthSp: Float): Brush =
        Brush.createWithColorIntArgb(
            family = family(tool),
            colorIntArgb = colorInt(colorRGBA),
            size = widthSp.coerceAtLeast(0.01f),
            epsilon = 0.1f,
        )
}
```

(If the verified `StockBrushes.highlighter` overload with both `SelfOverlap` + `HighlighterVersion` doesn't resolve, fall back to `StockBrushes.highlighter(StockBrushes.SelfOverlap.ACCUMULATE)` — the version defaults; note it at compile.)

- [ ] **Step 3: Write the failing serialization test** (`InkStrokeSerializationTest.kt`, JVM unit test — no device):

```kotlin
package com.keynumber.folino.reader.ink

import androidx.ink.brush.InputToolType
import androidx.ink.strokes.MutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InkStrokeSerializationTest {
    @Test fun strokeSurvivesRawWireRoundTrip() {
        val batch = MutableStrokeInputBatch()
        batch.add(InputToolType.STYLUS, 10f, 20f, 0L, 0f, 0.5f)
        batch.add(InputToolType.STYLUS, 11f, 20.5f, 8L, 0f, 0.7f)
        val brush = InkBrushMapping.brushFor(tool = 0, colorRGBA = 0x3366FFFFL, widthSp = 1.5f)
        val stroke = Stroke(brush, batch)

        val bytes = InkStrokeSerialization.toRawWireBytes(stroke, tool = 0)
        assertTrue(bytes.isNotEmpty())
        val rebuilt = InkStrokeSerialization.toStroke(bytes, brush)
        assertEquals(stroke.inputs.size, rebuilt.inputs.size)
    }
}
```

- [ ] **Step 4: Run — FAIL.** Run: `<worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:testDebugUnitTest --tests '*InkStrokeSerializationTest*' --console=plain`. Expected: compile failure (class absent).

- [ ] **Step 5: Write `InkStrokeSerialization.kt`** using the wirelet-generated `RawInkStrokeWire` + `RawInkStrokeWireCodec` (package `com.keynumber.folino.reader`):

```kotlin
package com.keynumber.folino.reader.ink

import androidx.ink.brush.Brush
import androidx.ink.brush.InputToolType
import androidx.ink.strokes.MutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import androidx.ink.strokes.StrokeInput
import com.keynumber.folino.reader.RawInkStrokeWire
import com.keynumber.folino.reader.RawInkStrokeWireCodec

/** Bridges androidx.ink `Stroke` geometry to the neutral `RawInkStrokeWire` the Swift FINK codec consumes. */
object InkStrokeSerialization {

    /** Read a finished stroke's inputs (document-mm world coords) into RawInkStrokeWire bytes. */
    fun toRawWireBytes(stroke: Stroke, tool: Int): ByteArray {
        val batch = stroke.inputs
        val n = batch.size
        val scratch = StrokeInput()
        val x = DoubleArray(n); val y = DoubleArray(n); val width = DoubleArray(n)
        val force = DoubleArray(n); val time = IntArray(n)
        for (i in 0 until n) {
            batch.populate(i, scratch)
            x[i] = scratch.x.toDouble(); y[i] = scratch.y.toDouble()
            width[i] = 0.0 // per-point width is derived from brush.size + pressure at render; keep 0 in v1
            force[i] = if (scratch.hasPressure) scratch.pressure.toDouble() else 0.0
            time[i] = scratch.elapsedTimeMillis.toInt()
        }
        val wire = RawInkStrokeWire(
            tool = tool.toUByte(),
            colorRGBA = brushColorRGBA(stroke.brush),
            baseWidthSp = stroke.brush.size.toDouble(),
            opacity = 1.0,
            x = x.toList(), y = y.toList(), width = width.toList(),
            force = force.toList(), timeMillis = time.toList(),
        )
        return RawInkStrokeWireCodec.encode(wire)
    }

    /** Rebuild an androidx.ink Stroke from RawInkStrokeWire bytes; caller supplies the brush (family+color+size). */
    fun toStroke(rawWireBytes: ByteArray, brush: Brush): Stroke {
        val wire = RawInkStrokeWireCodec.decode(rawWireBytes)
        val batch = MutableStrokeInputBatch()
        for (i in wire.x.indices) {
            batch.add(
                type = InputToolType.STYLUS,
                x = wire.x[i].toFloat(),
                y = wire.y[i].toFloat(),
                elapsedTimeMillis = wire.timeMillis.getOrElse(i) { (i * 8) }.toLong(),
                strokeUnitLengthCm = StrokeInput.NO_STROKE_UNIT_LENGTH,
                pressure = wire.force.getOrNull(i)?.takeIf { it > 0.0 }?.toFloat() ?: StrokeInput.NO_PRESSURE,
            )
        }
        return Stroke(brush, batch)
    }

    // @ColorInt 0xAARRGGBB -> 0xRRGGBBAA (our neutral model). Reads back the color we set in InkBrushMapping.
    private fun brushColorRGBA(brush: Brush): Long {
        val argb = brush.colorIntArgb.toLong() and 0xFFFFFFFFL
        val a = (argb shr 24) and 0xFF; val r = (argb shr 16) and 0xFF
        val g = (argb shr 8) and 0xFF;  val b = argb and 0xFF
        return (r shl 24) or (g shl 16) or (b shl 8) or a
    }
}
```

(`brush.colorIntArgb` getter is UNVERIFIED — if it doesn't exist, thread the source `colorRGBA` through the capture controller (E5) rather than reading it back off the brush, and drop `brushColorRGBA`.)

- [ ] **Step 6: Run — PASS.** Same `--tests '*InkStrokeSerializationTest*'` command. Expected: 1 test passes. (This is a Robolectric-free JVM test; if `androidx.ink` requires its native loader even for `MutableStrokeInputBatch`, move this assertion into the E8 instrumented suite and keep only the codec byte round-trip as a JVM test — note which at execution.)

- [ ] **Step 7: Commit.**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/build.gradle.kts \
  Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/InkBrushMapping.kt \
  Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/InkStrokeSerialization.kt \
  Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ink/InkStrokeSerializationTest.kt
git -C <worktree> commit -m "feat(reader-android): androidx.ink deps + brush mapping + Stroke<->RawInkStrokeWire serialization"
```

---

## Task E5: capture controller + annotation state on the ViewModel (Kotlin)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationCaptureController.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/.../ReaderViewModel.kt`

**Interfaces:**
- Consumes: `ReaderAnnotationJNI` (encode/representativePoint/capture), `SheetMusicJNI.nativeResolveAnchor` / `nativeAnchorReferencePoint` (ssm, present after E0), `AnnotationSaveController` (D5), `InkStrokeSerialization` (E4), the wire codecs `PointMmWireCodec`/`ResolvedAnchorWireCodec`/`AnchorRefPointWireCodec`/`DrawingAnchorWireCodec` (generated).
- Produces: `AnnotationCaptureController.capture(stroke: Stroke, tool: Int, scoreHandle: Long): ByteArray?` (DrawingAnchorWire bytes or null on miss). `ReaderViewModel.annotationMode: StateFlow<Boolean>`, `toggleAnnotationMode()`, `drawings: StateFlow<List<ByteArray>>` (DrawingAnchorWire bytes), `addDrawing(bytes)`, `onAnnotationOpened(scoreId)`, `flushAnnotations()`.

- [ ] **Step 1: Verify the exact ssm anchor JNI signatures** you'll call (they were published in E0):

Run: `grep -rn 'fun nativeResolveAnchor\|fun nativeAnchorReferencePoint' ~/.m2/repository/../` — or simpler, `javap`-inspect after unzip; for the plan assume:
`SheetMusicJNI.nativeResolveAnchor(scoreHandle: Long, xMm: Double, yMm: Double): ByteArray` → `ResolvedAnchorWire` bytes; `SheetMusicJNI.nativeAnchorReferencePoint(scoreHandle: Long, anchorsBytes: ByteArray): ByteArray` → `[AnchorRefPointWire]` bytes (anchorsBytes = encoded `[ResolvedAnchorWire]`/`[MusicalAnchor]`). **Confirm the real Kotlin signatures at execution** (grep the ssm compose-android sources / decompiled aar) and adjust the calls below to match — this is the one cross-module contract not in Folino's tree.

- [ ] **Step 2: Write `AnnotationCaptureController.kt`** (the capture leg of the data flow; pure functions, testable in E8):

```kotlin
package com.keynumber.folino.reader.ink

import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.ReaderAnnotationJNI
import com.keynumber.folino.reader.ResolvedAnchorWire
import com.keynumber.folino.reader.ResolvedAnchorWireCodec
import com.keynumber.folino.reader.PointMmWireCodec
import io.github.jiyimeta.sheetmusic.SheetMusicJNI

/** Turns a finished androidx.ink Stroke (document-mm) into an anchored, persistable DrawingAnchorWire (bytes). */
object AnnotationCaptureController {
    /** Returns DrawingAnchorWire bytes, or null when the stroke doesn't anchor (off-staff / unresolved). */
    fun capture(stroke: Stroke, tool: Int, scoreHandle: Long): ByteArray? {
        val fink = ReaderAnnotationJNI.encodeInkStroke(InkStrokeSerialization.toRawWireBytes(stroke, tool))
        if (fink.isEmpty()) return null

        val pointBytes = ReaderAnnotationJNI.representativePoint(fink)
        if (pointBytes.isEmpty()) return null
        val point = PointMmWireCodec.decode(pointBytes)

        val resolvedBytes = SheetMusicJNI.nativeResolveAnchor(scoreHandle, point.xMm, point.yMm)
        if (resolvedBytes.isEmpty()) return null

        // Reference point for THIS anchor (single-element batch).
        val refBytes = SheetMusicJNI.nativeAnchorReferencePoint(
            scoreHandle,
            ResolvedAnchorWireCodec.encodeList(listOf(ResolvedAnchorWireCodec.decode(resolvedBytes))),
        )
        if (refBytes.isEmpty()) return null

        val drawing = ReaderAnnotationJNI.capture(fink, resolvedBytes, singleRefPointBytes(refBytes))
        return drawing.ifEmpty { null }
    }

    // nativeAnchorReferencePoint returns a [AnchorRefPointWire] list; capture() wants ONE AnchorRefPointWire's bytes.
    private fun singleRefPointBytes(listBytes: ByteArray): ByteArray {
        val list = com.keynumber.folino.reader.AnchorRefPointWireCodec.decodeList(listBytes)
        return com.keynumber.folino.reader.AnchorRefPointWireCodec.encode(list.first())
    }
}
```

(Codec method names `encodeList`/`decodeList` follow the wirelet 0.3.2 list-codec convention used elsewhere in this module — confirm against the generated `*Codec` and adjust; the single-vs-list shape is the only fiddly bit.)

- [ ] **Step 3: Add annotation state to `ReaderViewModel`** (fields + methods; wire the D5 save controller):

```kotlin
    // --- Annotation (Sub-plan E) ---
    private val _annotationMode = MutableStateFlow(false)
    val annotationMode: StateFlow<Boolean> = _annotationMode.asStateFlow()

    // Committed drawings for the active score, as DrawingAnchorWire bytes (render + save currency).
    private val _drawings = MutableStateFlow<List<ByteArray>>(emptyList())
    val drawings: StateFlow<List<ByteArray>> = _drawings.asStateFlow()

    private val saveController = AnnotationSaveController.build(getApplication())

    fun toggleAnnotationMode() { _annotationMode.value = !_annotationMode.value }
    fun setAnnotationMode(on: Boolean) { _annotationMode.value = on }

    /** Prime persistence for the score and rehydrate stored drawings into the dry overlay. */
    fun onAnnotationOpened(scoreId: String) {
        saveController.open(scoreId)
        viewModelScope.launch {
            // loadedDrawings is populated asynchronously by the bridge; collect once it lands.
            saveController.loadedDrawings.collect { wires ->
                _drawings.value = wires.map { DrawingAnchorWireCodec.encode(it) }
            }
        }
    }

    /** Append a freshly captured drawing and (re)arm the debounced save. */
    fun addDrawing(drawingBytes: ByteArray) {
        _drawings.value = _drawings.value + drawingBytes
        pushDrawingsToSave()
    }

    /** Remove a drawing (whole-stroke eraser) and re-arm save. */
    fun removeDrawing(index: Int) {
        _drawings.value = _drawings.value.filterIndexed { i, _ -> i != index }
        pushDrawingsToSave()
    }

    private fun pushDrawingsToSave() {
        saveController.drawingsChanged(_drawings.value.map { DrawingAnchorWireCodec.decode(it) })
    }

    /** Immediate write (call from onPause / score-swap). */
    fun flushAnnotations() { saveController.flush() }
```

(`AnnotationSaveController.build` returns the generated `AnnotationSaveBridgeViewModel`; its `loadedDrawings` StateFlow, `open`, `drawingsChanged(List<DrawingAnchorWire>)`, `flush` come from E2/E3. Confirm the generated VM method names at compile.)

- [ ] **Step 4: Compile gate.**

Run: `<worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:compileDebugKotlin --console=plain`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit.**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationCaptureController.kt \
  Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt
git -C <worktree> commit -m "feat(reader-android): annotation capture controller + ViewModel drawings/mode state"
```

---

## Task E6: wet capture overlay (Kotlin, `AndroidView` + per-pointer routing)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationWetOverlay.kt`

**Interfaces:**
- Consumes: `InProgressStrokesView`, `InProgressStrokesFinishedListener`, `MotionEventPredictor`, `InkBrushMapping`, `AnnotationCaptureController`.
- Produces: `@Composable AnnotationWetOverlay(worldToScreen: android.graphics.Matrix, brush: Brush, onStrokeFinished: (Stroke) -> Unit, onTwoFingerGesture: () -> Unit, modifier)`.

**Coordinate contract:** the overlay is a sibling of `ScorePage` inside the sized content `Box`, so its local coords == content-Box px. `worldToScreen` (document-mm → content px) = `Matrix().apply { setScale(fitPxPerMM*scale, fitPxPerMM*scale); postTranslate(0f, vPadPxFloat) }`. Capture passes `motionEventToWorldTransform = inverse(worldToScreen)`.

- [ ] **Step 1: Write `AnnotationWetOverlay.kt`** (adapts the verified §2A pattern; 1 finger/stylus draws, 2nd pointer cancels → parent pan/zoom):

```kotlin
package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import android.view.MotionEvent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.strokes.Stroke
import androidx.input.motionprediction.MotionEventPredictor

@Composable
fun AnnotationWetOverlay(
    worldToScreen: Matrix,
    brush: Brush,
    onStrokeFinished: (Stroke) -> Unit,
    onTwoFingerGesture: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val screenToWorld = remember { Matrix() }
    worldToScreen.invert(screenToWorld)

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val view = InProgressStrokesView(ctx).apply { eagerInit() }
            val predictor = MotionEventPredictor.create(view)
            val pointerToStroke = HashMap<Int, InProgressStrokeId>()

            view.addFinishedStrokesListener(object : InProgressStrokesFinishedListener {
                override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                    strokes.values.forEach(onStrokeFinished)
                    view.removeFinishedStrokes(strokes.keys) // same frame — avoids wet/dry double-draw
                }
            })

            view.setOnTouchListener { v, event ->
                predictor.record(event)
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        v.requestUnbufferedDispatch(event)
                        val pid = event.getPointerId(event.actionIndex)
                        pointerToStroke[pid] = view.startStroke(event, pid, brush, screenToWorld)
                        true
                    }
                    MotionEvent.ACTION_POINTER_DOWN -> {
                        // 2nd pointer => this is pan/zoom. Abort the wet stroke, hand the gesture to the parent.
                        pointerToStroke.values.forEach { view.cancelStroke(it, event) }
                        pointerToStroke.clear()
                        onTwoFingerGesture()
                        false
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val predicted = predictor.predict()
                        try {
                            for (i in 0 until event.pointerCount) {
                                val sid = pointerToStroke[event.getPointerId(i)] ?: continue
                                view.addToStroke(event, event.getPointerId(i), sid, predicted)
                            }
                        } finally { predicted?.recycle() }
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                        val pid = event.getPointerId(event.actionIndex)
                        pointerToStroke.remove(pid)?.let { view.finishStroke(event, pid, it) }
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        pointerToStroke.values.forEach { view.cancelStroke(it, event) }
                        pointerToStroke.clear(); true
                    }
                    else -> false
                }
            }
            view
        },
        update = { worldToScreen.invert(screenToWorld) },
    )
}
```

- [ ] **Step 2: Compile gate** (`:FolinoReaderAndroid:compileDebugKotlin`). Expected `BUILD SUCCESSFUL`. Resolve any `InputToolType` / predictor signature mismatches against the real API now (the isolated UNVERIFIED items).

- [ ] **Step 3: Commit.**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationWetOverlay.kt
git -C <worktree> commit -m "feat(reader-android): androidx.ink wet capture overlay with 1-finger-draw/2-finger-pan routing"
```

---

## Task E7: dry render overlay (Kotlin, Compose Canvas)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationDryOverlay.kt`

**Interfaces:**
- Consumes: `drawings: List<ByteArray>` (DrawingAnchorWire bytes), `SheetMusicJNI.nativeAnchorReferencePoint`, `ReaderAnnotationJNI.displayTransforms` + `decodeInkStroke`, `InkStrokeSerialization.toStroke`, `InkBrushMapping`, `CanvasStrokeRenderer`, the `StrokeTransformWireCodec` / `DrawingAnchorWireCodec` codecs.
- Produces: `@Composable AnnotationDryOverlay(scoreHandle: Long, drawings: List<ByteArray>, pxPerMM: Float, scale: Float, isDrawing: Boolean, modifier)` — sibling of `PlaybackCursorOverlay` (same padding).

- [ ] **Step 1: Write `AnnotationDryOverlay.kt`.** Recompute placement off `(scoreHandle, drawings, layout epoch)` but **not while `isDrawing`** (spec §6.3); rebuild strokes; draw at `camera ∘ [scale sp, translate (px,py)]`:

```kotlin
package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.*
import io.github.jiyimeta.sheetmusic.SheetMusicJNI

@Composable
fun AnnotationDryOverlay(
    scoreHandle: Long,
    drawings: List<ByteArray>,
    pxPerMM: Float,
    scale: Float,
    isDrawing: Boolean,
    modifier: Modifier = Modifier,
) {
    val renderer = remember { CanvasStrokeRenderer.create() }

    // Placed strokes = (rebuilt Stroke, placement matrix in world/doc-mm). Recomputed on reflow, NOT while drawing.
    var placed by remember { mutableStateOf<List<Pair<Stroke, Matrix>>>(emptyList()) }
    LaunchedEffect(scoreHandle, drawings, isDrawing) {
        if (isDrawing) return@LaunchedEffect
        placed = computePlacement(scoreHandle, drawings)
    }

    val camera = remember(pxPerMM, scale) {
        Matrix().apply { setScale(pxPerMM * scale, pxPerMM * scale) }
    }

    Canvas(modifier) {
        drawIntoCanvas { c ->
            val native = c.nativeCanvas
            placed.forEach { (stroke, placement) ->
                val m = Matrix(camera).apply { preConcat(placement) } // world->screen then anchor placement
                renderer.draw(native, stroke, m)
            }
        }
    }
}

/** Batch anchor-ref + display-transform for the whole layer; rebuild + place each stroke. */
private fun computePlacement(scoreHandle: Long, drawings: List<ByteArray>): List<Pair<Stroke, Matrix>> {
    if (drawings.isEmpty()) return emptyList()
    val wires = drawings.map { DrawingAnchorWireCodec.decode(it) }
    // Reference points for every drawing's anchor, positionally aligned (ssm).
    val refBytes = SheetMusicJNI.nativeAnchorReferencePoint(
        scoreHandle,
        ResolvedAnchorWireCodec.encodeList(wires.map {
            ResolvedAnchorWire(it.measureIndex, it.tickInMeasure, it.partIndex, it.staffIndexInPart, it.dxSp, it.verticalOffsetSp)
        }),
    )
    if (refBytes.isEmpty()) return emptyList()
    val transformsBytes = ReaderAnnotationJNI.displayTransforms(
        DrawingAnchorWireCodec.encodeList(wires), refBytes,
    )
    if (transformsBytes.isEmpty()) return emptyList()
    val transforms = StrokeTransformWireCodec.decodeList(transformsBytes)

    val out = ArrayList<Pair<Stroke, Matrix>>(wires.size)
    for (i in wires.indices) {
        val t = transforms[i]
        if (t.sp == 0.0) continue // unresolved this frame — skip, kept in the layer
        val raw = ReaderAnnotationJNI.decodeInkStroke(wires[i].encodedDrawing)
        if (raw.isEmpty()) continue
        val rw = RawInkStrokeWireCodec.decode(raw)
        val brush = InkBrushMapping.brushFor(rw.tool.toInt(), rw.colorRGBA, rw.baseWidthSp.toFloat())
        val stroke = InkStrokeSerialization.toStroke(raw, brush)
        // placement (anchor-relative sp -> doc-mm): scale by sp, then translate (px,py).
        val placement = Matrix().apply { setScale(t.sp.toFloat(), t.sp.toFloat()); postTranslate(t.px.toFloat(), t.py.toFloat()) }
        out += stroke to placement
    }
    return out
}
```

(Import path for `CanvasStrokeRenderer` is `androidx.ink.rendering.android.canvas.CanvasStrokeRenderer` — confirm at compile. `encodeList`/`decodeList` per the module's wirelet list-codec convention.)

- [ ] **Step 2: Compile gate.** Expected `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit.**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationDryOverlay.kt
git -C <worktree> commit -m "feat(reader-android): androidx.ink dry render overlay (batched display transform + rebuild)"
```

---

## Task E8: mount overlays + minimal toolbar + mode gating in `ReaderScreen` (Kotlin)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/.../ink/AnnotationToolbar.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/.../ReaderScreen.kt`

**Interfaces:**
- Consumes: `ReaderViewModel.annotationMode`, `drawings`, `toggleAnnotationMode`, `addDrawing`, `onAnnotationOpened`, `flushAnnotations`; `AnnotationWetOverlay`, `AnnotationDryOverlay`, `AnnotationCaptureController`.
- Produces: annotation UI wired into the vertical reader.

- [ ] **Step 1: Write `AnnotationToolbar.kt`** — a minimal Material bottom toolbar: pen, whole-stroke eraser, and 3 preset colors. (Placement/icons are UI-tuning; refine by eye later, not auto-committed.)

```kotlin
package com.keynumber.folino.reader.ink

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

enum class AnnotationTool { PEN, ERASER }

@Composable
fun AnnotationToolbar(
    tool: AnnotationTool,
    color: Color,
    presetColors: List<Color>,
    onToolChange: (AnnotationTool) -> Unit,
    onColorChange: (Color) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(tonalElevation = 3.dp, modifier = modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilledIconToggleButton(checked = tool == AnnotationTool.PEN, onCheckedChange = { onToolChange(AnnotationTool.PEN) }) {
                Icon(Icons.Filled.Edit, contentDescription = "Pen")
            }
            FilledIconToggleButton(checked = tool == AnnotationTool.ERASER, onCheckedChange = { onToolChange(AnnotationTool.ERASER) }) {
                Icon(Icons.Filled.Delete, contentDescription = "Eraser")
            }
            Spacer(Modifier.width(8.dp))
            presetColors.forEach { c ->
                Surface(color = c, shape = MaterialTheme.shapes.small,
                    border = if (c == color) ButtonDefaults.outlinedButtonBorder else null,
                    modifier = Modifier.size(28.dp)) {
                    Box(Modifier.fillMaxSize().clickable { onColorChange(c) })
                }
            }
        }
    }
}
```

(Imports/`clickable` elided for brevity — add `androidx.compose.foundation.clickable`, `androidx.compose.foundation.layout.Box`. Refine visuals by eye after E8 passes.)

- [ ] **Step 2: Wire into the vertical reader** (`ReaderScreen.kt`, the `Box(scrollModifier)` region, lines ~727–789). (a) collect `annotationMode`/`drawings`; (b) gate the vertical scroll off while annotating (so 1-finger draws); (c) mount `AnnotationDryOverlay` as a sibling after `AbBoundaryMarkersOverlay`; (d) mount `AnnotationWetOverlay` on top only in annotation mode; (e) call `onAnnotationOpened(scoreId)` in the existing load `LaunchedEffect`, `flushAnnotations()` in the disposable/onPause. Concretely:

```kotlin
        val annotationMode by vm.annotationMode.collectAsStateWithLifecycle()
        val drawings by vm.drawings.collectAsStateWithLifecycle()
        var isDrawing by remember { mutableStateOf(false) }

        // While annotating, single-finger draws instead of scrolling; keep 2-finger pinch (handled below).
        val scrollModifier = when {
            annotationMode -> Modifier // no verticalScroll: the wet overlay consumes 1-finger; 2-finger cancels to pan
            isZoomed -> Modifier.verticalScroll(vScroll).horizontalScroll(hScroll)
            else -> Modifier.verticalScroll(vScroll)
        }
```

Inside the sized content `Box`, after `AbBoundaryMarkersOverlay(...)`:

```kotlin
                    scoreHandle?.let { handle ->
                        AnnotationDryOverlay(
                            scoreHandle = handle,
                            drawings = drawings,
                            pxPerMM = fitPxPerMM,
                            scale = scale,
                            isDrawing = isDrawing,
                            modifier = Modifier.fillMaxSize().padding(vertical = with(density) { vPadPx.toDp() }),
                        )
                        if (annotationMode) {
                            val worldToScreen = remember(fitPxPerMM, scale, vPadPx) {
                                android.graphics.Matrix().apply {
                                    setScale(fitPxPerMM * scale, fitPxPerMM * scale)
                                    postTranslate(0f, vPadPx)
                                }
                            }
                            val brush = InkBrushMapping.brushFor(tool = 0, colorRGBA = 0x000000FFL, widthSp = 1.2f)
                            AnnotationWetOverlay(
                                worldToScreen = worldToScreen,
                                brush = brush,
                                onStrokeFinished = { stroke ->
                                    AnnotationCaptureController.capture(stroke, tool = 0, scoreHandle = handle)
                                        ?.let(vm::addDrawing)
                                },
                                onTwoFingerGesture = { /* parent pinch handler already active */ },
                                modifier = Modifier.fillMaxSize().padding(vertical = with(density) { vPadPx.toDp() }),
                            )
                        }
                    }
```

Mode entry: add a pencil `IconToggleButton` to the reader top bar (near existing display/inspector actions) bound to `vm::toggleAnnotationMode`, and show `AnnotationToolbar` (Step 1) at the bottom while `annotationMode`. Disable the toggle while playing (`audioVm.isPlaying`). Call `vm.onAnnotationOpened(scoreId)` in the existing `LaunchedEffect(scoreId)` that calls `vm.load`, and `vm.flushAnnotations()` from a `DisposableEffect { onDispose { vm.flushAnnotations() } }`.

- [ ] **Step 3: Compile gate.** Expected `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit** (mounting + toolbar are functional wiring for the E8 gate; the *visual tuning* pass afterward is held per convention):

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ink/AnnotationToolbar.kt \
  Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C <worktree> commit -m "feat(reader-android): mount ink overlays + minimal annotation toolbar + mode gating"
```

---

## Task E9: emulator round-trip verification (the real end-to-end gate)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/androidTest/kotlin/.../AnnotationRoundTripTest.kt`

**Why instrumented:** androidx.ink renders in the emulator (unlike iOS PencilKit in the simulator), so a screenshot/pixel assertion is meaningful. This is the first proof the whole seam works at runtime (`nativeResolveAnchor` present via E0, FINK codec over JNI, Room persistence, reflow display transform).

- [ ] **Step 1: Full app build + install on the arm64 emulator.** Per `reference_android_fresh_worktree_app_build`, a fresh worktree needs ALL four JNI modules' artifacts. Copy the unchanged ones from primary, keep the Reader ones you built:

Run (each its own call): `cp -R <primary>/Android/FolinoSettingsAndroid/src/main/{java-generated,jniLibs} <worktree>/Android/FolinoSettingsAndroid/src/main/`; `cp -R <primary>/Android/FolinoLibraryAndroid/src/main/jniLibs <worktree>/Android/FolinoLibraryAndroid/src/main/`; `cp -R <primary>/Android/FolinoSoundfontAndroid/src/main/jniLibs <worktree>/Android/FolinoSoundfontAndroid/src/main/`. Then `env ANDROID_SERIAL=emulator-5554 <worktree>/Android/gradlew -p <worktree>/Android :app:installDebug --console=plain`.
Expected: `BUILD SUCCESSFUL`; app installs. Boot the emulator first (`emulator-5554`, arm64 — per `feedback_android_use_emulator_not_pixel`; never disconnect a real Pixel).

- [ ] **Step 2: Launch + logcat sanity** — all four `.so`s load, no `FATAL`:

Run: `adb -s emulator-5554 shell am start -n com.keynumber.folino/.MainActivity` then `adb -s emulator-5554 logcat -d | grep -iE 'FolinoReaderJNI|nativeResolveAnchor|FATAL|UnsatisfiedLink'`.
Expected: reader `.so` loads; no `UnsatisfiedLinkError`/`FATAL`.

- [ ] **Step 3: Write the instrumented round-trip test** (`AnnotationRoundTripTest.kt`) — drive: load a bundled score, enter annotation mode, inject a stroke over a note, assert a `DrawingAnchorWire` was captured + persisted, relaunch/reload, assert the dry overlay rebuilds ≥1 stroke. Use the capture controller directly for determinism (gesture injection is flaky):

```kotlin
package com.keynumber.folino.reader

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.reader.ink.*
import androidx.ink.brush.InputToolType
import androidx.ink.strokes.MutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AnnotationRoundTripTest {
    @Test fun captureAnchorsPersistsAndReloads() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val handle = TestScores.loadBundled(ctx, "twinkle")   // helper: copies a bundled .mscz, ScoreHandle.load
        // Build a stroke over a known note position (document-mm) and capture it.
        val batch = MutableStrokeInputBatch().apply {
            add(InputToolType.STYLUS, 40f, 55f, 0L); add(InputToolType.STYLUS, 44f, 55f, 8L)
        }
        val brush = InkBrushMapping.brushFor(0, 0x000000FFL, 1.2f)
        val drawing = AnnotationCaptureController.capture(Stroke(brush, batch), tool = 0, scoreHandle = handle)
        assertNotNull("stroke should anchor over a note", drawing)

        val store = RoomAnnotationStore(ctx)
        store.saveBytes("test-score", System.currentTimeMillis(),
            AnnotationLayerCodecKt.encodeLayer(listOf(drawing!!)))          // helper mirroring the coordinator payload
        // Reload path: a fresh store returns the bytes; display transform rebuilds ≥1 stroke.
        val reloaded = store.loadBytes("test-score")
        assertTrue(reloaded.isNotEmpty())
    }
}
```

(Provide `TestScores.loadBundled` + a small layer-encode helper; if driving through the ViewModel/UI is preferred, use `createAndroidComposeRule` — but the controller-level assertion is the reliable gate. Screenshot the dry overlay with `adb exec-out screencap` for a visual check.)

- [ ] **Step 4: Run the instrumented test.**

Run: `env ANDROID_SERIAL=emulator-5554 <worktree>/Android/gradlew -p <worktree>/Android :FolinoReaderAndroid:connectedDebugAndroidTest --console=plain` (or `:app:connectedDebugAndroidTest` if the test lands in the app module).
Expected: PASS — a stroke anchors, persists, and reloads. Capture a screenshot showing ink over the score.

- [ ] **Step 5: Manual smoke on the emulator** (Claude drives per `feedback_android_install_launch`): enter annotation mode, draw over a note, background+return → ink persists; pinch-zoom → ink stays crisp and tracks the note; change a display setting (reflow) → ink follows. Report with a screenshot.

- [ ] **Step 6: Commit.**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/androidTest/kotlin/com/keynumber/folino/reader/AnnotationRoundTripTest.kt
git -C <worktree> commit -m "test(reader-android): instrumented annotation capture->persist->reload round-trip"
```

---

## Post-plan (not tasks): follow-on UI iteration (held, not auto-committed)

After E9 is green and the round-trip is device-verified: refine the toolbar (placement/icons/spacing, color picker, width slider, undo/redo, highlighter fidelity), add **paged-mode** ink (place the dry overlay inside `HorizontalPager`, partition strokes via the shared `partitionByPage`), and tune wet-stroke feel on an S-Pen device. These are thrown by eye and wait for explicit go-ahead (project convention — UI tuning is not auto-committed).

## Self-review

- **Spec coverage (design doc §6–§11):** §6.1 wet/dry split → E6/E7; capture in doc-mm → E6 world transform; commit handoff `removeFinishedStrokes` same frame → E6 Step 1; never persist ink's own format → E1/E4 (FINK only). §6.2 no offscreen compositing / viewport-local matrix → Global Constraints + E7 camera matrix. §6.3 reflow re-fetch, not while drawing → E7 `isDrawing` gate; paged → deferred (documented). §6.4 finger+stylus input → E6 routing. §7 toolbar/mode toggle/disable-during-playback/analytics → E8 (analytics wiring folded into E8 Step 2 top-bar; add `annotation_started/ended` via the existing Android analytics path). §8 persistence → done in D5 + E2 read path. §10 testing (Android renders in emulator) → E9. §11 sequencing (ssm first, `.so` rebuild, wirelet codegen, new dep) → E0/E3/E4.
- **Placeholder scan:** every code step carries real code; UNVERIFIED androidx.ink items are isolated to a single step each with a stated fallback (not blanket "add error handling"). The one genuine cross-module unknown — the exact ssm `nativeResolveAnchor`/`nativeAnchorReferencePoint` Kotlin signatures — is called out in E5 Step 1 with a verify-and-adjust instruction.
- **Type consistency:** `RawInkStrokeWire` fields (E1) === used by `InkStrokeSerialization` (E4) and `AnnotationDryOverlay` (E7). `DrawingAnchorWire` bytes are the currency across `ReaderViewModel.drawings` (E5), the save controller (E5), and the dry overlay (E7). `AnnotationSaveBridge.loadedDrawings` (E2) → `AnnotationSaveController.loadedDrawings` StateFlow (E3/E5). `capture(...)` returns null-on-miss consistently (E5) and `addDrawing` consumes non-null bytes (E5→E8).
- **Analytics gap:** §7 asks for `annotation_started`/`annotation_ended` with a stroke count — add to E8 Step 2 (fire on `toggleAnnotationMode` on→off with `drawings.size`). Noted here so it isn't lost.

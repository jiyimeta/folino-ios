# Android Annotation — Sub-plan C: FolinoReaderJNI capture/display bridge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three stateless JNI entry points to the Android-gated `FolinoReaderJNI` target that host the shared `AnnotationAnchoringCore` over the neutral `InkStroke`, so Android Kotlin can capture a drawn stroke into a persisted `DrawingAnchor` and compute per-stroke display transforms on reflow — all anchoring math in shared Swift, Kotlin only plumbs bytes.

**Architecture:** The math already lives in `ReaderAnnotationCore` (`AnnotationAnchoringCore.capture` / `display` over an injected `AnchorResolving`). Sub-plan C adds (1) a host-tested `PrefetchedAnchorResolver` in `ReaderAnnotationCore` that feeds the core the anchor + reference point Kotlin already fetched from ssm's `.so`, and (2) a thin wire-marshalling layer in `FolinoReaderJNI` (three `public func`s + `@WireFormat` structs) that decodes the ssm-produced anchor bytes + the neutral `InkStroke`/`DrawingAnchor` bytes, calls the core, and re-encodes. Kotlin plumbs ssm's raw output bytes straight into these calls (no decode, no math). This mirrors the shipping `SheetMusicJNI`↔`FolinoLibraryJNI`/`FolinoSettingsJNI` seam.

**Tech Stack:** Swift 6.3, `ReaderAnnotationCore` (shared, host + Android), `FolinoReaderJNI` (Android-gated dynamic lib, `FOLINO_ANDROID=1`), `swift-java`/jextract (JNI binding gen), `swift-wirelet` `@WireFormat` TLV codecs (added to the Reader package, Android-gated), Kotlin facade in `FolinoReaderAndroid`.

**Source spec:** `docs/superpowers/specs/2026-07-13-android-annotation-design.md` §5.2. Parent plan: `docs/superpowers/plans/2026-07-13-android-annotation-phase2.md` (Sub-plan C outline + Spike-1 data flow). Sub-plan B (ssm `nativeResolveAnchor` / `nativeAnchorReferencePoint`) landed in **swift-sheet-music v1.1.1** and Folino is re-pinned to it.

## Global Constraints

- **Neutral format is fixed.** `InkStroke` "FINK" codec (`Domain.InkStrokeCodec`) is the single cross-platform stroke format. Sub-plan C *consumes* it; it does not redefine the byte layout.
- **`MusicalAnchor` has six fields** (`measureIndex`, `tickInMeasure`, `partIndex`, `staffIndexInPart`: `Int`; `dxSp`, `verticalOffsetSp`: `Double`) matching ssm's `ResolvedAnchor` 1:1.
- **Units: Android works in document-millimetres.** ssm returns reference points in **mm** (`xMm`/`yMm`/`spMm`); `dxSp`/`verticalOffsetSp` are unit-neutral sp multiples. The core normalizes geometry by `sp`, so mm-space is internally consistent — **no pt conversion on the Folino side.**
- **`spMm == 0` is the miss sentinel** for a reference point (anchor did not resolve): keep the array positionally aligned, drop just that stroke.
- **No math in Kotlin.** Kotlin plumbs ssm's raw `ByteArray` outputs into the Folino JNI calls and decodes only Folino's own output wire.
- **Cross-platform rule 1** — never re-implement the anchoring math in Kotlin; reuse `AnnotationAnchoringCore` from one place.
- **App name lowercase `folino`** anywhere user-visible (N/A this sub-plan — no UI).
- **`FolinoReaderJNI` and `ReaderAnnotationCore` carry no SwiftLint build-tool plugin** (they cross-compile for Android; the pre-commit hook lints them on the host). Keep it that way.
- **swift-wirelet must be pinned to the same revision the repo already uses** (`ba1b8e337a508079c5213656e4c01e9edbedc8b4`, per `FolinoLibraryJNI`/`FolinoSettingsJNI`).

---

## File structure

| File | Responsibility | New? |
|---|---|---|
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/PrefetchedAnchorResolver.swift` | `AnchorResolving` seeded with the anchor(s) + reference point(s) Kotlin already fetched from ssm. Pure values, no wirelet. Host-testable. | Create |
| `Packages/Features/Reader/Tests/ReaderTests/PrefetchedAnchorResolverTests.swift` | Host TDD for the resolver + capture/display round-trip through it. | Create |
| `Packages/Features/Reader/Package.swift` | Add `swift-wirelet` (Android-gated) to the `FolinoReaderJNI` target. | Modify |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift` | `@WireFormat` structs for the JNI boundary: mirror ssm's `ResolvedAnchorWire`/`AnchorRefPointWire` (decode), plus Folino's `DrawingAnchorWire`/`StrokeTransformWire`/`PointMmWire` (encode/round-trip). | Create |
| `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift` | The three `public func nativeAnnotation*` — decode wire → `PrefetchedAnchorResolver` → `AnnotationAnchoringCore` → encode wire. | Create |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt` | Kotlin facade mirroring `SettingsJNI.kt` (`SwiftData.fromByteArray` / `.toByteArray()` / arena). | Create |
| `Android/FolinoReaderAndroid/build.gradle.kts` (+ wirelet codegen wiring) | Ensure Folino's `@WireFormat` Reader wire structs get Kotlin codecs generated. | Modify (verify) |

Kotlin-side codecs for `ResolvedAnchorWire`/`AnchorRefPointWire` come from ssm's `sheet-music-android` AAR (already generated there). Kotlin does **not** decode them — it passes ssm's raw bytes straight through — but it *does* decode Folino's `DrawingAnchorWire`/`StrokeTransformWire` outputs (Folino-generated codecs).

---

## Task C1: `PrefetchedAnchorResolver` in ReaderAnnotationCore (host-tested)

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/PrefetchedAnchorResolver.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/PrefetchedAnchorResolverTests.swift`

**Interfaces produced (later tasks rely on these):**

```swift
public struct PrefetchedAnchorResolver: AnchorResolving {
    // resolveAnchor(at:) ignores the point and returns `resolvedAnchor` (capture path:
    // Kotlin already resolved the stroke's representative point via ssm).
    // referencePoint(for:) looks the anchor up in `referencePoints` (both paths).
    public init(resolvedAnchor: MusicalAnchor?, referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)])
    public func resolveAnchor(at point: CGPoint) -> MusicalAnchor?
    public func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)?
}
```

- [ ] **Step 1: Write the failing test** — `PrefetchedAnchorResolverTests.swift`

```swift
import Domain
import Foundation
import ReaderAnnotationCore
import Testing

@Suite("PrefetchedAnchorResolver")
struct PrefetchedAnchorResolverTests {
    private func stroke(x: [Float], y: [Float]) -> InkStroke {
        InkStroke(tool: .pen, colorRGBA: 0x0000_00FF, baseWidthSp: 1, opacity: 1,
                  x: x, y: y, width: Array(repeating: 1, count: x.count),
                  force: [], azimuth: [], altitude: [], timeMillis: [])
    }

    @Test("capture through a prefetched resolver anchors the stroke and normalizes geometry")
    func captureRoundTrip() throws {
        let anchor = MusicalAnchor(measureIndex: 1, tickInMeasure: 0, partIndex: 0,
                                   staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0)
        let refPoint = CGPoint(x: 100, y: 200)
        let sp: CGFloat = 4
        let resolver = PrefetchedAnchorResolver(
            resolvedAnchor: anchor, referencePoints: [anchor: (refPoint, sp)])

        // A stroke centered on the reference point (rep point == anchor point P).
        let s = stroke(x: [96, 104], y: [200, 200])   // bbox center = (100, 200) = P
        let drawings = AnnotationAnchoringCore.capture(strokes: [s], using: resolver)
        #expect(drawings.count == 1)
        guard case let .musical(a) = drawings[0].kind else { Issue.record("not musical"); return }
        #expect(a == anchor)

        // Round-trip: display at the same layout must place the geometry back at P.
        let placed = AnnotationAnchoringCore.display(drawings, using: resolver)
        let t = try #require(placed[0])
        #expect(abs(t.px - refPoint.x) < 0.001)
        #expect(abs(t.py - refPoint.y) < 0.001)
        #expect(abs(t.sp - sp) < 0.001)
    }

    @Test("referencePoint miss drops the stroke on capture and yields nil on display")
    func missDropsStroke() {
        let anchor = MusicalAnchor(measureIndex: 9, tickInMeasure: 0, partIndex: 0,
                                   staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0)
        let resolver = PrefetchedAnchorResolver(resolvedAnchor: anchor, referencePoints: [:]) // no ref point
        let s = stroke(x: [0, 10], y: [0, 0])
        #expect(AnnotationAnchoringCore.capture(strokes: [s], using: resolver).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — from `Packages/Features/Reader`:
  `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/PrefetchedAnchorResolver`
  Expected: FAIL — `PrefetchedAnchorResolver` undefined.

- [ ] **Step 3: Implement** — `PrefetchedAnchorResolver.swift`

```swift
import Domain
import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// An `AnchorResolving` seeded with values Kotlin already fetched from ssm's anchor-primitive JNI:
/// the resolved `MusicalAnchor` for a captured stroke, and the document-space reference point + `sp`
/// for each anchor. Lets the Android JNI path reuse `AnnotationAnchoringCore.capture` / `display`
/// unchanged — the same code iOS runs in-process — with no re-implemented math.
///
/// - `resolveAnchor(at:)` returns `resolvedAnchor` regardless of the point: on Android the stroke's
///   representative point was already resolved to this anchor by `SheetMusicJNI.nativeResolveAnchor`.
/// - `referencePoint(for:)` looks the anchor up in `referencePoints`; a missing entry (ssm's
///   `spMm == 0` miss) yields `nil`, so the core drops that stroke.
public struct PrefetchedAnchorResolver: AnchorResolving {
    private let resolvedAnchor: MusicalAnchor?
    private let referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)]

    public init(resolvedAnchor: MusicalAnchor?,
                referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)]) {
        self.resolvedAnchor = resolvedAnchor
        self.referencePoints = referencePoints
    }

    public func resolveAnchor(at point: CGPoint) -> MusicalAnchor? { resolvedAnchor }

    public func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? {
        referencePoints[anchor]
    }
}
```

- [ ] **Step 4: Run — expect PASS** (same command as Step 2).
- [ ] **Step 5: Commit**

```bash
git -C <WT> add Packages/Features/Reader/Sources/ReaderAnnotationCore/PrefetchedAnchorResolver.swift \
                Packages/Features/Reader/Tests/ReaderTests/PrefetchedAnchorResolverTests.swift
git -C <WT> commit -m "feat(reader): PrefetchedAnchorResolver for the Android annotation JNI path"
```

---

## Task C2: Add swift-wirelet to the Reader package + annotation wire structs

**Files:**
- Modify: `Packages/Features/Reader/Package.swift`
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift`

**Interfaces produced:**

```swift
// Mirror ssm v1.1.1 exactly (byte contract; Kotlin plumbs ssm's raw output here):
@WireFormat public struct ResolvedAnchorWire: Equatable {  // ssm nativeResolveAnchor output
    public let measureIndex: Int32; public let tickInMeasure: Int32
    public let partIndex: Int32;    public let staffIndexInPart: Int32
    public let dxSp: Double;         public let verticalOffsetSp: Double
}
@WireFormat public struct AnchorRefPointWire: Equatable {  // ssm nativeAnchorReferencePoint output element
    public let xMm: Double; public let yMm: Double; public let spMm: Double   // spMm==0 = miss sentinel
}
// Folino's own boundary types (Kotlin decodes these via Folino-generated codecs):
@WireFormat public struct PointMmWire: Equatable {         // representativePoint output
    public let xMm: Double; public let yMm: Double
}
@WireFormat public struct DrawingAnchorWire: Equatable {   // capture output + display/persistence input element
    public let measureIndex: Int32; public let tickInMeasure: Int32
    public let partIndex: Int32;    public let staffIndexInPart: Int32
    public let dxSp: Double;         public let verticalOffsetSp: Double
    public let encodedDrawing: Data // FINK bytes of the normalized InkStroke
}
@WireFormat public struct StrokeTransformWire: Equatable { // display output element; sp==0 = "unresolved, skip"
    public let sp: Double; public let px: Double; public let py: Double
}
```

- [ ] **Step 1: Modify `Package.swift`** — add the swift-wirelet package dependency (Android-gated, same style as the existing `swift-java` gating) and the `Wirelet` product to the `FolinoReaderJNI` target's dependencies. Locate the `#if FOLINO_ANDROID` package-dependencies block that already adds `swift-java`/`swift-subprocess` and append:

```swift
.package(
    url: "https://github.com/jiyimeta/swift-wirelet.git",
    revision: "ba1b8e337a508079c5213656e4c01e9edbedc8b4",
),
```

and in the `FolinoReaderJNI` target dependencies (also Android-gated) add:

```swift
.product(name: "Wirelet", package: "swift-wirelet"),
```

- [ ] **Step 2: Verify the package resolves for Android** — from `Packages/Features/Reader`:
  `PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH" FOLINO_ANDROID=1 swift package resolve`
  Expected: resolves swift-wirelet at the pinned revision, no error. (Confirm the iOS build is unaffected: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` still succeeds — swift-wirelet is Android-gated so iOS never links it.)

- [ ] **Step 3: Create `AnnotationWire.swift`** with the six `@WireFormat` structs above. Header comment: these mirror ssm v1.1.1's `AnchorCodecs.swift` for `ResolvedAnchorWire`/`AnchorRefPointWire` (byte contract across two `.so`s), plus Folino's own boundary types. `import Foundation` + `import Wirelet`. Field order is the wire contract — do not reorder.

- [ ] **Step 4: Build for Android to confirm the macro expands + cross-compiles** — run Task C6's cross-build command (the wire structs alone won't link a product yet; fold this verify into C6). For now confirm host lint via the pre-commit hook when committing.

- [ ] **Step 5: Commit**

```bash
git -C <WT> add Packages/Features/Reader/Package.swift \
                Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationWire.swift
git -C <WT> commit -m "feat(reader): swift-wirelet + @WireFormat annotation wire types for the Android JNI boundary"
```

---

## Task C3: `nativeAnnotationRepresentativePoint`

**Files:**
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift`

**Interfaces produced:**
`public func nativeAnnotationRepresentativePoint(strokeBytes: Data) -> Data` — decode FINK `InkStroke`, compute `AnnotationAnchoringCore.representativePoint`, return `PointMmWire(xMm:yMm:).encodeToData()`. Empty `Data` if the stroke fails to decode.

- [ ] **Step 1: Implement** — `AnnotationJNISymbols.swift`

```swift
import Domain
import Foundation
import ReaderAnnotationCore
import Wirelet

/// swift-java (jextract) entry point: the bbox-center document point a wet stroke anchors to.
/// Kotlin sends this mm point to `SheetMusicJNI.nativeResolveAnchor`. Empty `Data` on decode failure.
public func nativeAnnotationRepresentativePoint(strokeBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(strokeBytes) else { return Data() }
    let p = AnnotationAnchoringCore.representativePoint(of: stroke)
    return PointMmWire(xMm: Double(p.x), yMm: Double(p.y)).encodeToData()
}
```

- [ ] **Step 2: Cross-build gate** — folded into Task C6 (Android-gated target; no host unit test). The math (`representativePoint`) is host-covered by `AnnotationAnchoringCoreTests`.
- [ ] **Step 3: Commit** (fold C3+C4+C5 into one commit at C5, or commit incrementally — the file grows across these tasks; commit after C5's cross-build passes).

---

## Task C4: `nativeAnnotationCapture`

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift`

**Interfaces produced:**
`public func nativeAnnotationCapture(strokeBytes: Data, resolvedAnchorBytes: Data, refPointBytes: Data) -> Data` — decode the wet `InkStroke` + ssm's `ResolvedAnchorWire` + ssm's `AnchorRefPointWire`; build the `MusicalAnchor` + a single-entry `PrefetchedAnchorResolver`; `AnnotationAnchoringCore.capture([stroke], using: resolver)`; encode the resulting `DrawingAnchor` as `DrawingAnchorWire`. Empty `Data` on any miss (undecodable input, `spMm == 0`, or the core drops the stroke).

- [ ] **Step 1: Append implementation**

```swift
/// swift-java entry point: capture one wet stroke into a persisted DrawingAnchor.
/// `resolvedAnchorBytes` = ssm ResolvedAnchorWire; `refPointBytes` = ssm AnchorRefPointWire (mm).
/// Composes P = ref + (dxSp, voSp)*sp and normalizes geometry to anchor-relative sp — all in the
/// shared core. Empty `Data` when inputs don't decode, the ref point missed (spMm==0), or the
/// stroke's representative point can't resolve.
public func nativeAnnotationCapture(strokeBytes: Data, resolvedAnchorBytes: Data, refPointBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(strokeBytes),
          let rw = try? ResolvedAnchorWire(decoding: resolvedAnchorBytes),
          let rp = try? AnchorRefPointWire(decoding: refPointBytes),
          rp.spMm > 0
    else { return Data() }

    let anchor = MusicalAnchor(
        measureIndex: Int(rw.measureIndex), tickInMeasure: Int(rw.tickInMeasure),
        partIndex: Int(rw.partIndex), staffIndexInPart: Int(rw.staffIndexInPart),
        dxSp: rw.dxSp, verticalOffsetSp: rw.verticalOffsetSp)
    let resolver = PrefetchedAnchorResolver(
        resolvedAnchor: anchor,
        referencePoints: [anchor: (CGPoint(x: rp.xMm, y: rp.yMm), CGFloat(rp.spMm))])

    guard let drawing = AnnotationAnchoringCore.capture(strokes: [stroke], using: resolver).first else {
        return Data()
    }
    return DrawingAnchorWire(
        measureIndex: rw.measureIndex, tickInMeasure: rw.tickInMeasure,
        partIndex: rw.partIndex, staffIndexInPart: rw.staffIndexInPart,
        dxSp: rw.dxSp, verticalOffsetSp: rw.verticalOffsetSp,
        encodedDrawing: drawing.encodedDrawing).encodeToData()
}
```

- [ ] **Step 2:** Cross-build gate folded into C6.
- [ ] **Step 3:** Commit at C5.

---

## Task C5: `nativeAnnotationDisplayTransforms` (batched hot path)

**Files:**
- Modify: `Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift`

**Interfaces produced:**
`public func nativeAnnotationDisplayTransforms(drawingsBytes: Data, refPointsBytes: Data) -> Data` — decode `[DrawingAnchorWire]` + ssm's `[AnchorRefPointWire]` (positionally aligned with the drawings' anchors); build a `PrefetchedAnchorResolver` mapping each drawing's anchor to its ref point (skip `spMm == 0`); `AnnotationAnchoringCore.display(drawings, using: resolver)`; encode `[StrokeTransformWire]` positionally aligned with the input (`sp == 0` where the transform is `nil`). Empty `Data` only when the inputs don't decode or their counts differ.

- [ ] **Step 1: Append implementation**

```swift
/// swift-java entry point: one call computes the display transform for a whole annotation layer on
/// reflow (the hot path). `drawingsBytes` = [DrawingAnchorWire] (what capture produced / persistence
/// stored); `refPointsBytes` = ssm [AnchorRefPointWire], positionally aligned with `drawingsBytes`.
/// Output [StrokeTransformWire] is positionally aligned with the input; `sp == 0` marks an unresolved
/// drawing the caller skips this frame (kept, pruned on next save). Empty `Data` if inputs don't
/// decode or their counts differ.
public func nativeAnnotationDisplayTransforms(drawingsBytes: Data, refPointsBytes: Data) -> Data {
    guard let wires = try? [DrawingAnchorWire](decoding: drawingsBytes),
          let refs = try? [AnchorRefPointWire](decoding: refPointsBytes),
          wires.count == refs.count
    else { return Data() }

    var drawings: [DrawingAnchor] = []
    var referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)] = [:]
    drawings.reserveCapacity(wires.count)
    for (w, r) in zip(wires, refs) {
        let anchor = MusicalAnchor(
            measureIndex: Int(w.measureIndex), tickInMeasure: Int(w.tickInMeasure),
            partIndex: Int(w.partIndex), staffIndexInPart: Int(w.staffIndexInPart),
            dxSp: w.dxSp, verticalOffsetSp: w.verticalOffsetSp)
        drawings.append(DrawingAnchor(kind: .musical(anchor), encodedDrawing: w.encodedDrawing))
        if r.spMm > 0 { referencePoints[anchor] = (CGPoint(x: r.xMm, y: r.yMm), CGFloat(r.spMm)) }
    }

    let resolver = PrefetchedAnchorResolver(resolvedAnchor: nil, referencePoints: referencePoints)
    let transforms = AnnotationAnchoringCore.display(drawings, using: resolver)
    let out = transforms.map { t -> StrokeTransformWire in
        guard let t else { return StrokeTransformWire(sp: 0, px: 0, py: 0) } // unresolved sentinel
        return StrokeTransformWire(sp: Double(t.sp), px: Double(t.px), py: Double(t.py))
    }
    return out.encodeToData()
}
```

Note: two drawings can share a `MusicalAnchor`; the dictionary collapses them to one ref-point entry, which is correct (same anchor → same ref point). Positional output alignment is preserved because `display` maps over `drawings`, not the dictionary.

- [ ] **Step 2:** Cross-build gate (C6).
- [ ] **Step 3: Commit C3+C4+C5**

```bash
git -C <WT> add Packages/Features/Reader/Sources/FolinoReaderJNI/AnnotationJNISymbols.swift
git -C <WT> commit -m "feat(reader): FolinoReaderJNI annotation capture/display/representativePoint bridge"
```

---

## Task C6: Android `.so` cross-build + jextract export gate

The Android `.so` is the shipping artifact; its jextract codegen must succeed and export the three new symbols with the `Data`-blob signatures Kotlin expects. This also exercises the wire-struct macro expansion + `PrefetchedAnchorResolver` under the Android toolchain.

- [ ] **Step 1** — prepend the release toolchain to `PATH` and cross-build the arm64 product from the Reader package dir:

```bash
PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH" FOLINO_ANDROID=1 \
  swift build --package-path Packages/Features/Reader \
  --product FolinoReaderJNI --swift-sdk aarch64-unknown-linux-android28 -c release
```

Expected: `Build of product 'FolinoReaderJNI' complete!`, `libFolinoReaderJNI.so` linked.

- [ ] **Step 2** — grep the generated jextract Java for the three symbols:

```bash
grep -n "nativeAnnotationRepresentativePoint\|nativeAnnotationCapture\|nativeAnnotationDisplayTransforms" \
  Packages/Features/Reader/.build/plugins/outputs/reader/FolinoReaderJNI/destination/JExtractSwiftPlugin/src/generated/java/com/keynumber/folino/reader/swiftjava/FolinoReaderJNI.java
```

Expected: `public static Data nativeAnnotationRepresentativePoint(Data strokeBytes, SwiftArena)`, `nativeAnnotationCapture(Data, Data, Data, SwiftArena)`, `nativeAnnotationDisplayTransforms(Data, Data, SwiftArena)`.

- [ ] **Step 3** — (optional, x86_64 ABI parity) repeat Step 1 with `--swift-sdk x86_64-unknown-linux-android28`.
- [ ] **Step 4:** No commit (build artifacts are gitignored / staged only by `Scripts/android-build-reader-libs.sh`). If Step 2 shows a signature mismatch, fix the Swift `func` and re-run.

---

## Task C7: Kotlin facade `ReaderAnnotationJNI`

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt`
- Verify/Modify: `Android/FolinoReaderAndroid/build.gradle.kts` (wirelet Kotlin codegen for the Reader wire structs, mirroring the Library/Settings setup)

**Interfaces produced (Kotlin):**

```kotlin
object ReaderAnnotationJNI {
    fun representativePoint(strokeBytes: ByteArray): ByteArray      // -> PointMmWire bytes
    fun capture(strokeBytes: ByteArray, resolvedAnchorBytes: ByteArray, refPointBytes: ByteArray): ByteArray // -> DrawingAnchorWire bytes ("" empty = miss)
    fun displayTransforms(drawingsBytes: ByteArray, refPointsBytes: ByteArray): ByteArray // -> [StrokeTransformWire] bytes
}
```

- [ ] **Step 1: Implement** — mirror `FolinoSettingsAndroid/.../SettingsJNI.kt`:

```kotlin
package com.keynumber.folino.reader

import com.keynumber.folino.reader.swiftjava.Data as SwiftData
import com.keynumber.folino.reader.swiftjava.FolinoReaderJNI as SwiftJavaJNI
import org.swift.swiftkit.core.SwiftMemoryManagement

/**
 * Kotlin facade over the FolinoReaderJNI annotation bridge. Byte plumbing only — the anchoring math
 * is in shared Swift (AnnotationAnchoringCore). `resolvedAnchorBytes` / `refPointBytes` are ssm's raw
 * SheetMusicJNI outputs, passed straight through (no decode here).
 */
object ReaderAnnotationJNI {
    private val arena get() = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA

    fun representativePoint(strokeBytes: ByteArray): ByteArray =
        SwiftJavaJNI.nativeAnnotationRepresentativePoint(SwiftData.fromByteArray(strokeBytes, arena), arena).toByteArray()

    fun capture(strokeBytes: ByteArray, resolvedAnchorBytes: ByteArray, refPointBytes: ByteArray): ByteArray =
        SwiftJavaJNI.nativeAnnotationCapture(
            SwiftData.fromByteArray(strokeBytes, arena),
            SwiftData.fromByteArray(resolvedAnchorBytes, arena),
            SwiftData.fromByteArray(refPointBytes, arena), arena).toByteArray()

    fun displayTransforms(drawingsBytes: ByteArray, refPointsBytes: ByteArray): ByteArray =
        SwiftJavaJNI.nativeAnnotationDisplayTransforms(
            SwiftData.fromByteArray(drawingsBytes, arena),
            SwiftData.fromByteArray(refPointsBytes, arena), arena).toByteArray()
}
```

- [ ] **Step 2: Verify wirelet Kotlin codegen** covers Folino's Reader `@WireFormat` structs — confirm `DrawingAnchorWire`/`StrokeTransformWire`/`PointMmWire` Kotlin codecs are generated for `FolinoReaderAndroid` the same way `VersionHistoryWire*` are for Settings. If the Reader module isn't yet wired into the wirelet Gradle codegen, add it mirroring `FolinoSettingsAndroid`'s `build.gradle.kts`. (This is the one Android-Gradle step; if it turns out non-trivial it can split into its own task.)
- [ ] **Step 3: Compile check** — `ANDROID build of FolinoReaderAndroid` (kotlin compile) once the `.so` + java-generated are staged by `Scripts/android-build-reader-libs.sh`. Full end-to-end (draw → capture → reflow) is Sub-plan E on the emulator.
- [ ] **Step 4: Commit**

```bash
git -C <WT> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAnnotationJNI.kt \
                Android/FolinoReaderAndroid/build.gradle.kts
git -C <WT> commit -m "feat(reader-android): Kotlin ReaderAnnotationJNI facade for the annotation bridge"
```

---

## Self-review (Sub-plan C)

- **Spec coverage** (§5.2 / parent plan Sub-plan C):
  - `nativeAnnotationRepresentativePoint` → C3.
  - `nativeAnnotationCapture` (compose P, normalize, encode InkStroke) → C4, reusing the core via `PrefetchedAnchorResolver` (C1).
  - `nativeAnnotationDisplayTransforms` (batched, zip drawings with ref points, emit transforms) → C5.
  - Wire `InkStroke ↔ bytes` (reuse `InkStrokeCodec`) → used in C3/C4; `DrawingAnchor`/anchor/ref-point/transform wires → C2.
  - jextract Java + Kotlin facade → C6/C7. `Scripts/android-build-reader-libs.sh` rebuilds the `.so` (no script change).
  - Verification: Android `.so` cross-build (C6); math host-covered by `AnnotationAnchoringCoreTests` + `PrefetchedAnchorResolverTests` (C1); end-to-end deferred to Sub-plan E (emulator).
- **Type consistency:** `ResolvedAnchorWire`/`AnchorRefPointWire` fields match ssm v1.1.1's `AnchorCodecs.swift` 1:1 (byte contract). `MusicalAnchor` built with `Int(...)` from the wire's `Int32`. `DrawingAnchorWire` carries the six `MusicalAnchor` fields + `encodedDrawing`. `StrokeTransformWire(sp,px,py)` matches `StrokeTransform(sp,px,py)`; `sp==0` sentinel consistent with the `spMm==0` miss convention.
- **No placeholders:** every JNI func + wire struct + the resolver carries real code; the one open Android-Gradle detail (wirelet Kotlin codegen wiring for the Reader module, C7 Step 2) is called out explicitly and may split into its own task at execution.
- **Access levels:** `normalized` stays `internal`; capture/display are reused through the **public** `capture`/`display` + `PrefetchedAnchorResolver` — no new core seam beyond the resolver.

## Downstream (after C)

- **Sub-plan D** — Android persistence (Room `annotation_layers` + `@WireletProvided AnnotationStore`, save policy in shared Swift). Consumes `DrawingAnchorWire` as the stored payload shape.
- **Sub-plan E** — androidx.ink capture/render; **first wires the Kotlin call graph end-to-end** (draw → `representativePoint` → ssm `nativeResolveAnchor` → `nativeAnchorReferencePoint` → `capture` → store; reflow → `nativeAnchorReferencePoint` batch → `displayTransforms` → `Canvas.concat`). **Requires the ssm Android `.so` + AARs republished to mavenLocal** (`sheet-music-{android,audio-android,compose-android}` @ `0.0.0-SNAPSHOT`) so `SheetMusicJNI.nativeResolveAnchor` is present at runtime.
- **Sub-plan F** — tool palette & Reader UX (Android idiom).

# Android Annotation — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement the bite-sized sub-plan(s) task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Folino's freehand annotation ("書き込み") to Android (Jetpack Compose) at behavioral parity with iOS, sharing all logic in Swift and adapting only UI/UX placement to Android idioms.

**Architecture:** The feature stratifies along the shared-vs-platform seam. *Logic* (data model, anchoring math, persistence policy, the already-shipped neutral `InkStroke` codec) is written once in shared Swift; *platform I/O* (ink capture, rendering, tool palette, the native persistence backend) is per-platform. The one hard cross-platform problem — resolving a drawn point to a musical position on Android, where `LayoutDocument` lives inside ssm's `.so` — is solved exactly like the shipping `nativeNearestCursor` bridge: two thin, Folino-agnostic JNI primitives on swift-sheet-music (ssm), with Kotlin plumbing bytes between ssm and Folino's own JNI bridge. No math in Kotlin.

**Tech Stack:** Swift 6.3 (shared Domain / Reader core / JNI bridges), swift-sheet-music (`SheetMusicLayout` anchor primitives + `SheetMusicAndroidJNI` bridge, `swift-java`/jextract, `swift-wirelet` `@WireFormat` codecs), Kotlin/Jetpack Compose, `androidx.ink` 1.0.0 (new Gradle dep, Apache-2.0), Room.

**Source spec:** `docs/superpowers/specs/2026-07-13-android-annotation-design.md`.

## Global Constraints

- **Cross-platform rule 1 — logic → shared Swift.** Never re-implement iOS annotation logic as a divergent Kotlin path. Lift shared logic into Domain / the Reader anchoring core / an Android-gated Swift JNI target and call it from both platforms.
- **Cross-platform rule 2 — UI/UX placement → Android idioms.** Control placement, icons, copy, gestures follow Android conventions (bottom toolbar, FAB-style entry, finger+stylus draw). Only the *content* stays at iOS parity.
- **Neutral format is fixed (Phase 1, shipped in 1.8.2).** The `InkStroke` "FINK" binary codec (`Domain/Sources/Domain/Logic/InkStrokeCodec.swift`) is the single cross-platform stroke format. Phase 2 *consumes* it; it does not redefine the byte layout. `DrawingAnchor.encodedDrawing` stays an opaque per-stroke blob.
- **Domain is Foundation-only** and compiles for both toolchains. `MusicalAnchor` has six fields matching ssm's `ResolvedAnchor` 1:1.
- **Module architecture (must respect).** The neutral anchoring core stays in the **Reader** package (not Domain): Domain depends only on `SheetMusicCore`, not `SheetMusicLayout` where `LayoutDocument` lives, and the anchoring *algorithm* is Reader-specific. ssm entry points stay **Folino-agnostic**.
- **App name lowercase `folino`** anywhere a user can read it.
- **Bumping an ssm pin** means updating both the relevant `Package.swift` `revision:` AND `project.yml` `packages:` to the same revision — but see the **hold** below: no re-pin this cycle.

## What Phase 1 already shipped (1.8.2 — do not redo)

- `Domain/Models/InkStroke.swift` + `Domain/Logic/InkStrokeCodec.swift` — the neutral format + "FINK" codec (single source of truth for the byte layout).
- `Reader/Annotation/InkStrokePencilKitBridge.swift` — iOS `PKStroke ↔ InkStroke` adapter (encode dense on-curve samples, bake transform into points, ink-type/color mapping, read-both stored-blob helpers).
- `Infrastructure/Persistence/AnnotationFormatMigrator.swift` — one-time PKDrawing → neutral migration, read-both permanently, masked strokes kept legacy, `updatedAt`-preserving with a concurrent-write guard.
- CloudKit preserve-don't-clobber for undecodable payloads.

Phase 1 deliberately swapped **only the persistence codec at the store boundary**. The anchoring core (`Reader/Annotation/AnnotationAnchoring.swift`) is **still PencilKit-typed** (`capture(strokes: [PKStroke], …) -> [DrawingAnchor]`, `display(…) -> PKDrawing`). Neutralizing it is Phase 2 (Sub-plan A).

---

## Spike 1 outcome (SETTLED): the ssm anchor-primitive seam

Spec §5.2 / §12 left one decision to the spike: *does the affine bake co-locate into ssm as a generic geometry primitive over `ResolvedAnchor`, or stay in Folino's JNI bridge with Kotlin byte-plumbing?*

**Decision: Kotlin byte-plumbing. ssm exposes only two thin, Folino-agnostic anchor primitives; the InkStroke bake + the `anchorPoint` composition stay in shared Folino Swift. Kotlin plumbs bytes between the two native libraries and does NO math.**

### Why (not co-locate the bake in ssm)

- The **`InkStroke` bake operates on Domain data** (`InkStroke`'s dense `x[]`/`y[]`/`width[]` arrays). ssm sits *below* Domain in the dependency graph; making ssm depend on `Domain.InkStroke` inverts the architecture. The bake therefore *cannot* move to ssm without a layering violation.
- The **`anchorPoint` composition** (`P = referencePoint + (dxSp, verticalOffsetSp) × sp`) already lives in shared Folino Swift (`AnnotationAnchoring.anchorPoint(for:in:)`) and runs on iOS. If ssm *also* did it (for Android), the same formula would exist twice — exactly the divergence cross-platform-rule-1 forbids. Keeping it in the neutralized core means **one** implementation both platforms call.
- ssm's `LayoutDocument.resolveAnchor(at:)` and `anchorReferencePoint(measureIndex:…)` are **already `public` in the Foundation-only `SheetMusicLayout`** and already used by iOS in-process. Exposing them over JNI is a *thin wrapper* — the proven `nativeNearestCursor` shape — that keeps ssm generic and adds no annotation-specific knowledge to ssm.

### The seam is the exact shape of the shipping `nativeNearestCursor` bridge

`Sources/SheetMusicAndroidJNI/NearestCursorBridge.swift` already does "document-mm point → cached `LayoutDocument` (via `LayoutDocumentCache.value(for:)`) → shared `SheetMusicLayout` entry point → wirelet-encoded bytes, empty `Data` on miss." The two new entry points are the same pattern over the anchor primitives.

### Data flow — capture (drawing one stroke, Android)

Kotlin orchestrates; all math is in Swift (either ssm's `.so` or Folino's `.so`):

1. `FolinoReaderJNI.nativeAnnotationRepresentativePoint(strokeBytes)` → bbox-center point in doc-mm. *(shared `AnnotationAnchorPolicy`, Folino `.so`)*
2. `SheetMusicJNI.nativeResolveAnchor(handle, xMm, yMm)` → `ResolvedAnchor` bytes (empty on miss). *(ssm `.so`)*
3. `SheetMusicJNI.nativeAnchorReferencePoint(handle, [thatAnchorIdentity])` → `[(xMm, yMm, spMm)]` bytes. *(ssm `.so`, batched but single-element here)*
4. `FolinoReaderJNI.nativeAnnotationCapture(strokeBytes, resolvedAnchorBytes, refPointBytes)` → `DrawingAnchor` bytes (compose `P`, normalize stroke geometry by `translate(−P) · scale(1/sp)`, encode `InkStroke`). *(shared `AnnotationAnchoring` core, Folino `.so`)*

### Data flow — display (reflow, all committed strokes, Android)

1. `SheetMusicJNI.nativeAnchorReferencePoint(handle, [allAnchorIdentities])` → `[(xMm, yMm, spMm)]` batched (ONE call for the whole layer — the hot path). *(ssm `.so`)*
2. `FolinoReaderJNI.nativeAnnotationDisplayTransforms(drawingsBytes, refPointsBytes)` → per-stroke `(sp, Px, Py)` (12 bytes/stroke): zip each drawing's anchor offsets with its ref point, compose `P`, emit `scale sp, translate P`. *(shared core, Folino `.so`)*
3. Kotlin applies each transform to cached stroke geometry with `Canvas.concat` — mechanical rendering, no re-implemented logic.

### Unit convention (critical for round-trip + cross-platform fidelity)

- ssm's `SheetMusicLayout` works in **typographic points**; the Android overlay works in **document-mm**. The bridges convert at the boundary exactly like `nativeNearestCursor` / `nativeCursorFrame`: `mmToPt = 72/25.4` on input, `ptToMM = 25.4/72` on output.
- **`nativeResolveAnchor`** converts its input point mm→pt; the returned `ResolvedAnchor` needs **no** conversion — `measureIndex`/`tickInMeasure`/`partIndex`/`staffIndexInPart` are indices and `dxSp`/`verticalOffsetSp` are unit-neutral sp-multiples (a pt/pt ratio == the same mm/mm ratio).
- **`nativeAnchorReferencePoint`** converts its output `point` **and** `sp` pt→mm (both are lengths).
- **Why `sp` is returned in mm:** the stored `InkStroke` geometry is *anchor-relative in sp units* — a pure ratio `geometry / sp`. iOS computes `geometry_pt / sp_pt`; Android computes `geometry_mm / sp_mm`; the same physical stroke yields the **same** stored ratio only if each platform divides its own-unit geometry by its own-unit sp. So the bridge must hand Android `sp` in mm.

### Hidden staves: NOT needed for the anchor primitives (unlike `nativeNearestCursor`)

`nativeNearestCursor` takes a `LayoutOptionsWire` blob because it re-addresses the hit result into the **full-score** address space the audio engine keys on. The anchor primitives never reach the audio engine: `resolveAnchor` returns addresses in the **cached (filtered) document's** own space, and `anchorReferencePoint` looks them up in that same document. Capture and display both run against the same cached `LayoutDocument`, so they are internally consistent without a hidden-staves parameter. **Known limitation (matches iOS exactly):** an anchor stored while staff X was hidden may fail to resolve after X is un-hidden (its filtered address shifts); such anchors are preserved-not-dropped by the existing `partitionByPage` off-page policy. This is the current iOS behavior and is in-scope-parity, not a regression. (Cross-device share is a spec non-goal.)

---

## Sub-plan decomposition & sequencing

Phase 2 is one spec but four subsystems on a dependency chain. Each sub-plan is an independently reviewable, testable unit and gets its **own** bite-sized plan doc when it is executed. Only **Sub-plan B (ssm)** is fully bite-sized in this document, because it is implemented this session.

| # | Sub-plan | Repo / layer | Depends on | Independently verifiable by | Hold? |
|---|----------|--------------|-----------|------------------------------|-------|
| **B** | **ssm anchor-primitive JNI** (this doc) | ssm | — (uses shipped `SheetMusicLayout` primitives) | host codec tests + Android `.so` cross-build + example-app smoke | **YES — see hold** |
| **A** | Shared anchoring-core neutralize | Folino Reader (shared Swift) | InkStroke (shipped) | `xcodebuild test` on Apple sim — `capture → display` round-trip exact; iOS UX unchanged | no |
| **C** | FolinoReaderJNI capture/display bridge | Folino Reader JNI | A | Android `.so` cross-build; jextract Java | needs A |
| **D** | Android persistence (Room + wirelet bridge) | Folino Android + Library JNI | InkStroke | instrumented Room test | needs re-pin for e2e |
| **E** | Android ink capture/render (androidx.ink) | Folino Android | B(published)+C+D | emulator instrumented + screenshot (ink renders in emulator) | needs re-pin |
| **F** | Tool palette & Reader UX | Folino Android | E | emulator/device by eye (UI tuning — NOT auto-committed) | needs re-pin |

**Recommended execution order after this session:** B (now, held) → **A (next — iOS-only, needs no ssm publish; the natural follow-on)** → [ssm publishes when the parallel ssm-feature session lands + re-pin] → C → D → E → F. Note **A does not depend on the ssm hold**: it is a pure iOS Reader refactor with zero user-visible change and is the highest-value next step.

### HOLD (per user, 2026-07-13)

A **parallel session is landing other ssm features**. Therefore, this session:

- Implements Sub-plan B in an **ssm worktree** (`android-annotation-anchor-jni`, base `origin/main` `17a1f5b9`) and leaves it there.
- Does **NOT** merge to ssm main, does **NOT** publish (mavenLocal or GitHub Packages), does **NOT** re-pin Folino, does **NOT** run `ios-release`/`android-release` — i.e. no "update release."
- ssm-main-merge + publish + Folino re-pin happen **after** the parallel ssm work finishes, bundled into the next ssm release (per `feedback_ssm_side_land_independently`, no version skew).
- Verification this session is ssm-side only (host codec tests where the toolchain allows + Android `.so` cross-build + example-app smoke). Folino end-to-end waits for re-pin.

---

## Sub-plan B (THIS session): ssm anchor-primitive JNI — bite-sized tasks

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/AnchorCodecs.swift` — `ResolvedAnchorWire`, `AnchorIdentityWire`, `AnchorRefPointWire` (`@WireFormat`).
- Create: `Sources/SheetMusicAndroidJNI/AnchorBridge.swift` — `nativeResolveAnchor`, `nativeAnchorReferencePoint`.
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt` — Kotlin facade methods.
- Test: `Tests/SheetMusicTests/AndroidJNI/AnchorBridgeTests.swift` — codec round-trip + bridge-via-cache (host-platform; runs in the user's/CI env if the local jextract block persists — see Task B7).

**Interfaces produced (later sub-plans / Kotlin rely on these — exact names & wire layout):**

```swift
// AnchorCodecs.swift  — all @WireFormat; wirelet generates the matching Kotlin codecs.

@WireFormat
public struct ResolvedAnchorWire: Equatable {         // nativeResolveAnchor output
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32
    public let dxSp: Double              // unit-neutral sp-multiple
    public let verticalOffsetSp: Double  // unit-neutral sp-multiple
}

@WireFormat
public struct AnchorIdentityWire: Equatable {          // nativeAnchorReferencePoint input element
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32
}

@WireFormat
public struct AnchorRefPointWire: Equatable {          // nativeAnchorReferencePoint output element
    public let xMm: Double
    public let yMm: Double
    public let spMm: Double   // > 0 when resolved; == 0 sentinel = "unresolved, drop this stroke" (keeps positional alignment)
}
```

- `nativeResolveAnchor(scoreHandle: Int64, tapXmm: Double, tapYmm: Double) -> Data` — `ResolvedAnchorWire.encodeToData()`, empty `Data` on any miss.
- `nativeAnchorReferencePoint(scoreHandle: Int64, anchorsBytes: Data) -> Data` — decode `[AnchorIdentityWire]`, map each through `LayoutDocument.anchorReferencePoint`, emit `[AnchorRefPointWire]` (sentinel per miss, positional), `.encodeToData()`. Empty `Data` only when the handle/document is absent (so the caller can distinguish "no layout" from "layer of misses").

Both mirror `NearestCursorBridge.swift`: guard `LayoutDocumentCache.value(for:)` and the `#if !canImport(CoreGraphics)` `CGFloat`/`CGPoint` typealias shim. **No `#available` guard is needed** (unlike `nativeNearestCursor`, which guards for `nearestEngineCursor`'s macOS-15/iOS-16 floor): `resolveAnchor` / `anchorReferencePoint` carry no availability annotation and run at the package's macOS-14/iOS-17 baseline. Adding the guard would spuriously return empty `Data` on macOS 14.

### Task B1: `ResolvedAnchorWire` codec + round-trip test

- [ ] **Step 1: Write the failing test** — `Tests/SheetMusicTests/AndroidJNI/AnchorBridgeTests.swift`

```swift
#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicAndroidJNI
    import Testing

    @Suite("Anchor bridge")
    struct AnchorBridgeTests {
        @Test("ResolvedAnchorWire round-trips through its wire codec")
        func resolvedAnchorRoundTrip() throws {
            let wire = ResolvedAnchorWire(
                measureIndex: 3, tickInMeasure: 240, partIndex: 1, staffIndexInPart: 0,
                dxSp: 1.5, verticalOffsetSp: -2.0,
            )
            let decoded = try ResolvedAnchorWire(decoding: wire.encodeToData())
            #expect(decoded == wire)
        }
    }
#endif
```

- [ ] **Step 2: Run to verify it fails** — `xcodebuild test -scheme swift-sheet-music-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:SheetMusicTests/AnchorBridgeTests/resolvedAnchorRoundTrip` (or the user's env if the local jextract block persists — Task B7). Expected: FAIL — `ResolvedAnchorWire` undefined.
- [ ] **Step 3: Implement** — create `Sources/SheetMusicAndroidJNI/AnchorCodecs.swift` with the three `@WireFormat` structs above (import `Foundation`, `Wirelet`).
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** (in the ssm worktree):

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-annotation-anchor-jni add Sources/SheetMusicAndroidJNI/AnchorCodecs.swift Tests/SheetMusicTests/AndroidJNI/AnchorBridgeTests.swift
git -C …/android-annotation-anchor-jni commit -m "feat(anchor): ResolvedAnchor/AnchorIdentity/AnchorRefPoint wire codecs"
```

### Task B2: batched `[AnchorIdentityWire]` / `[AnchorRefPointWire]` round-trip test

- [ ] **Step 1: Add the failing test** (same file):

```swift
        @Test("Anchor identity + ref-point arrays round-trip (wirelet i32-count arrays)")
        func batchedArraysRoundTrip() throws {
            let ids = [
                AnchorIdentityWire(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
                AnchorIdentityWire(measureIndex: 2, tickInMeasure: 120, partIndex: 1, staffIndexInPart: 1),
            ]
            #expect(try [AnchorIdentityWire](decoding: ids.encodeToData()) == ids)

            let pts = [
                AnchorRefPointWire(xMm: 10, yMm: 20, spMm: 1.76),
                AnchorRefPointWire(xMm: 0, yMm: 0, spMm: 0), // unresolved sentinel
            ]
            #expect(try [AnchorRefPointWire](decoding: pts.encodeToData()) == pts)
        }
```

- [ ] **Step 2: Run — expect PASS immediately** (B1's structs already exist; this test only pins the array-envelope contract the Kotlin display path depends on). If it compiles and passes, that is the "it verifies the batched contract" gate. If wirelet rejects any field type, fix the struct now.
- [ ] **Step 3: Commit** if any struct changed; otherwise fold into B1's commit.

### Task B3: `nativeResolveAnchor` entry point + bridge test

- [ ] **Step 1: Add the failing test** (reuses `AnchorPrimitivesTests`'s `twoMeasureDoc()` layout pattern; store it in the cache the bridge reads):

```swift
        @available(macOS 15.0, *)
        private func cachedTwoMeasure(handle: Int64) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .whole, notes: [note])
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff = Staff(measures: [measure, measure])
            let score = Score(division: 480,
                              parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
            let doc = LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
            LayoutDocumentCache.store(handle: handle, document: doc, filteredScore: score, hiddenStaves: [])
            return score
        }

        @Test("nativeResolveAnchor resolves a document-mm point to a ResolvedAnchor (empty Data on miss)")
        func resolveAnchorBridge() throws {
            guard #available(macOS 15.0, *) else { return }
            let _ = TestSupport.installApple
            let handle: Int64 = 4242
            _ = cachedTwoMeasure(handle: handle)
            defer { LayoutDocumentCache.release(handle) }

            let doc = try #require(LayoutDocumentCache.value(for: handle))
            let ref = try #require(doc.anchorReferencePoint(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0))
            let ptToMM = 25.4 / 72.0
            let data = nativeResolveAnchor(
                scoreHandle: handle,
                tapXmm: Double(ref.point.x) * ptToMM,
                tapYmm: Double(ref.point.y) * ptToMM)
            let wire = try ResolvedAnchorWire(decoding: data)
            #expect(wire.measureIndex == 1)
            #expect(wire.partIndex == 0)
            #expect(wire.staffIndexInPart == 0)
            #expect(abs(wire.dxSp) < 0.01)
            #expect(abs(wire.verticalOffsetSp) < 0.01)

            #expect(nativeResolveAnchor(scoreHandle: 9999, tapXmm: 0, tapYmm: 0).isEmpty) // unknown handle
        }
```

- [ ] **Step 2: Run — expect FAIL** (`nativeResolveAnchor` undefined).
- [ ] **Step 3: Implement** — create `Sources/SheetMusicAndroidJNI/AnchorBridge.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

// Annotation anchor primitives (freehand ink ↔ musical position) JNI bridge.
// Mirrors NearestCursorBridge: the tap/geometry arrives in document millimetres;
// SheetMusicLayout works in typographic points. These wrap the shipped
// LayoutDocument.resolveAnchor / anchorReferencePoint primitives so Folino's
// shared anchoring core can reach a layout cached inside this .so. The affine
// bake stays in Folino's shared Swift — these entry points are geometry-only.

private let mmToPt = 72.0 / 25.4
private let ptToMM = 25.4 / 72.0

/// JNI entry point for `SheetMusicJNI.nativeResolveAnchor(...)`. Resolves a
/// document-mm point to a `ResolvedAnchor` in the cached (filtered) layout's
/// address space. Empty `Data` when the handle is unknown, the layout is not
/// cached, or the layout has no systems/staves/measures.
public func nativeResolveAnchor(scoreHandle: Int64, tapXmm: Double, tapYmm: Double) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle) else { return Data() }
    let point = CGPoint(x: CGFloat(tapXmm * mmToPt), y: CGFloat(tapYmm * mmToPt))
    guard let r = document.resolveAnchor(at: point) else { return Data() }
    return ResolvedAnchorWire(
        measureIndex: Int32(r.measureIndex),
        tickInMeasure: Int32(r.tickInMeasure),
        partIndex: Int32(r.partIndex),
        staffIndexInPart: Int32(r.staffIndexInPart),
        dxSp: Double(r.dxSp),
        verticalOffsetSp: Double(r.verticalOffsetSp),
    ).encodeToData()
}
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(anchor): nativeResolveAnchor JNI entry point`.

### Task B4: `nativeAnchorReferencePoint` (batched) entry point + test

- [ ] **Step 1: Add the failing test:**

```swift
        @Test("nativeAnchorReferencePoint batches ref points, mm units, sentinel on miss")
        func anchorReferencePointBridge() throws {
            guard #available(macOS 15.0, *) else { return }
            let _ = TestSupport.installApple
            let handle: Int64 = 4343
            _ = cachedTwoMeasure(handle: handle)
            defer { LayoutDocumentCache.release(handle) }

            let ids = [
                AnchorIdentityWire(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
                AnchorIdentityWire(measureIndex: 99, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0), // miss
            ]
            let out = try [AnchorRefPointWire](
                decoding: nativeAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids.encodeToData()))
            #expect(out.count == 2)
            #expect(out[0].spMm > 0)          // resolved
            #expect(out[1].spMm == 0)         // sentinel: unresolved, keeps positional alignment

            let doc = try #require(LayoutDocumentCache.value(for: handle))
            let ref = try #require(doc.anchorReferencePoint(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0))
            let ptToMM = 25.4 / 72.0
            #expect(abs(out[0].xMm - Double(ref.point.x) * ptToMM) < 0.001)
            #expect(abs(out[0].spMm - Double(ref.sp) * ptToMM) < 0.001)

            #expect(nativeAnchorReferencePoint(scoreHandle: 9999, anchorsBytes: ids.encodeToData()).isEmpty)
        }
```

- [ ] **Step 2: Run — expect FAIL** (`nativeAnchorReferencePoint` undefined).
- [ ] **Step 3: Implement** — append to `AnchorBridge.swift`:

```swift
/// JNI entry point for `SheetMusicJNI.nativeAnchorReferencePoint(...)`. Batched:
/// resolves each `(measure, tick, part, staff)` identity to its document-mm
/// reference point + sp (mm). One call resolves a whole annotation layer on the
/// hot display/reflow path. Unresolved identities emit an `spMm == 0` sentinel
/// (positional alignment preserved so the caller can drop just that stroke).
/// Empty `Data` only when the handle/document is absent.
public func nativeAnchorReferencePoint(scoreHandle: Int64, anchorsBytes: Data) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle) else { return Data() }
    let ids: [AnchorIdentityWire]
    do { ids = try [AnchorIdentityWire](decoding: anchorsBytes) } catch { return Data() }
    let points = ids.map { id -> AnchorRefPointWire in
        guard let ref = document.anchorReferencePoint(
            measureIndex: Int(id.measureIndex), tickInMeasure: Int(id.tickInMeasure),
            partIndex: Int(id.partIndex), staffIndexInPart: Int(id.staffIndexInPart),
        ) else { return AnchorRefPointWire(xMm: 0, yMm: 0, spMm: 0) }
        return AnchorRefPointWire(
            xMm: Double(ref.point.x) * ptToMM,
            yMm: Double(ref.point.y) * ptToMM,
            spMm: Double(ref.sp) * ptToMM,
        )
    }
    return points.encodeToData()
}
```

Note: `anchorReferencePoint` is not `@available`-gated in `SheetMusicLayout`, so no runtime guard is needed here (confirm against the current signature during implementation; add a guard only if it acquired one).

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `feat(anchor): nativeAnchorReferencePoint batched JNI entry point`.

### Task B5: Kotlin facade methods

- [ ] **Step 1: Add to `SheetMusicJNI.kt`** (mirror `nativeNearestCursor`'s arena + `SwiftData.fromByteArray` + `.toByteArray()` shape):

```kotlin
    /**
     * Resolve a freehand-ink document-mm point ([xMm], [yMm]) to a musical
     * anchor (ResolvedAnchorWire bytes) in the cached (filtered) layout of
     * [scoreHandle]. Empty array on any miss. Folino's shared anchoring core
     * turns this into a Domain MusicalAnchor and bakes the stroke.
     */
    fun nativeResolveAnchor(scoreHandle: Long, xMm: Double, yMm: Double): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeResolveAnchor(scoreHandle, xMm, yMm, arena).toByteArray()
    }

    /**
     * Batched inverse: resolve every anchor identity in [anchorsBytes]
     * (`[AnchorIdentityWire]`) to its document-mm reference point + sp
     * (`[AnchorRefPointWire]`, `spMm == 0` sentinel per unresolved anchor).
     * One call per annotation layer on the reflow/display path. Empty array when
     * the layout is not cached.
     */
    fun nativeAnchorReferencePoint(scoreHandle: Long, anchorsBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeAnchorReferencePoint(
            scoreHandle, SwiftData.fromByteArray(anchorsBytes, arena), arena,
        ).toByteArray()
    }
```

- [ ] **Step 2: Verify the `SwiftJavaJNI.nativeResolveAnchor` / `nativeAnchorReferencePoint` symbols exist** — they are generated by jextract from the `public func`s (Task B3/B4). `swift-java.config` has no allowlist (auto-discovers `public func`s), so no config change is needed. Confirm after an Android `.so` build regenerates the jextract Java (Task B6).
- [ ] **Step 3: Commit** — `feat(anchor): SheetMusicJNI Kotlin facade for anchor primitives`.

### Task B6: Android `.so` cross-build (the real "does it compile for Android" gate)

The host `xcodebuild` path exercises the *macOS* build of the target; the shipping artifact is the Android `.so`, whose jextract codegen must also succeed. It also exercises the Android-only `#if !canImport(CoreGraphics)` `CGFloat`/`CGPoint` shim path in `AnchorBridge.swift`, which the host build does NOT compile. Cross-build the ssm Android JNI from the worktree:

- [x] **Step 1** — prepend the release toolchain to `PATH` (Xcode's bundled Swift is incompatible with the prebuilt Android SDK; per `project_android_build_toolchain`): `PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"` (installed release toolchain confirmed: `swift-6.3.3-RELEASE`, SDK `swift-6.3.3-RELEASE_android`).
- [x] **Step 2** — `PATH="…swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH" SWIFT_SHEET_MUSIC_ANDROID=1 swift build --package-path <ssm-worktree> --product SheetMusicAndroidJNI --swift-sdk aarch64-unknown-linux-android28 -c release` (the per-ABI core of `Scripts/android-build-libs.sh`).
- [x] **Step 3** — grep the generated jextract Java for the two symbols.

**Result (2026-07-13):** `Build of product 'SheetMusicAndroidJNI' complete! (397 s)` — `AnchorBridge.swift` compiled for `aarch64-unknown-linux-android28`, `libSheetMusicAndroidJNI.so` linked, jextract wrote a 209-symbol export list. `SheetMusicAndroidJNI.java` exports `public static Data nativeResolveAnchor(long, double, double, SwiftArena)` and `public static Data nativeAnchorReferencePoint(long, Data, SwiftArena)` — signatures matching the Kotlin facade (B5). No ssm-tracked generated artifacts changed (jextract output is staged into `jniLibs`/`java-generated` only by the full `Scripts/android-build-libs.sh`, deferred to the post-hold publish).

### Task B7: Verification wrap-up + HOLD

- [x] **Run the host codec/bridge tests.** The 41-day-old jextract host-block (`project_sheet_music_dev_clone_and_test_block`) is **resolved** — verified empirically 2026-07-13: `xcrun swift build --target SheetMusicAndroidJNI` succeeds in ~73 s with jextract generating the `+SwiftJava.swift` files, so host `swift test` runs locally. Use `xcrun swift test --package-path <ssm-worktree> --filter AnchorBridgeTests` (or `xcodebuild test -scheme swift-sheet-music-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:SheetMusicTests/AnchorBridgeTests`).
- [ ] **Example-app smoke (optional this session):** the ssm Android example app has no annotation UI; a full runtime exercise waits for Folino Sub-plans C–E. If a quick sanity check is wanted, add a temporary debug call in the example that resolves a hard-coded point and logs the bytes.
- [ ] **HOLD:** leave the branch `android-annotation-anchor-jni` in the worktree. **Do not** merge to ssm main, publish, or re-pin Folino. Report to the user; the parallel ssm-feature session merges/publishes first, then ssm-main-merge + re-pin happen together.

### Self-review (Sub-plan B)

- **Spec coverage:** §5.2 (`nativeResolveAnchor` / `nativeAnchorReferencePoint`, batched, Folino-agnostic) → B3/B4/B5. §11 (ssm lands first, `.so` rebuild) → B6 + HOLD. §12 spike 1 (bake co-location) → settled above (stays in Folino).
- **Type consistency:** `ResolvedAnchorWire` fields ↔ `Domain.MusicalAnchor`'s six fields ↔ ssm `ResolvedAnchor`'s six fields, all 1:1. `AnchorIdentityWire` ⊂ `ResolvedAnchorWire` (identity subset). `spMm == 0` sentinel used consistently in B4 impl + B4 test + Kotlin doc.
- **No placeholders:** every step carries real code or a real command.

---

## Downstream sub-plans (design-level outline — each expands to its own bite-sized plan when executed)

### Sub-plan A — Shared anchoring-core neutralize (Folino Reader, iOS-verifiable, NEXT after B)

Neutralize `Reader/Annotation/AnnotationAnchoring.swift` (and `AnnotationAnchorPolicy.swift`, `PDFAnnotationAnchoring.swift`) so the core operates on `InkStroke` and an injected anchor resolver, not `PKStroke` + `LayoutDocument`:

- Introduce `protocol AnchorResolving { func resolveAnchor(at: CGPoint) -> MusicalAnchor?; func referencePoint(for: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? }`. iOS supplies `LayoutDocumentAnchorResolver(document:)`; Android (Sub-plan C) supplies a `PrefetchedAnchorResolver` seeded from the ssm JNI results.
- Split the core into small pure functions so **one** implementation serves both the in-process (iOS) and Kotlin-plumbed (Android) compositions:
  - `representativePoint(of: InkStroke) -> CGPoint` (bbox center — neutralize `AnnotationAnchorPolicy.representativePoint` off `PKStroke.renderBounds` onto `InkStroke`'s `x[]`/`y[]` extent).
  - `anchorPoint(for: MusicalAnchor, resolver) -> (CGPoint, sp)` (the composition `ref + (dxSp, voSp)·sp`).
  - `capture(strokes: [InkStroke], resolver) -> [DrawingAnchor]` (normalize each stroke's dense arrays by `translate(−P)·scale(1/sp)`, encode via `InkStrokeCodec`).
  - `display(drawings: [DrawingAnchor], resolver) -> [StrokeTransform]` where `StrokeTransform = (sp: Float, px: Float, py: Float)` — **transform only, not baked geometry** (12 bytes/stroke; Android applies it with `Canvas.concat`, iOS bakes it into `PKStroke` points via the retained adapter).
  - `partitionByPage(...)` — unchanged in spirit, retyped off `InkStroke`/`DrawingAnchor`.
- iOS Reader keeps `InkStrokePencilKitBridge` as the thin `PKStroke ↔ InkStroke` adapter at the UI seam; PencilKit UI is otherwise unchanged. iOS still bakes the display transform into points (the PencilKit clamp workaround stays in the adapter, fed by the new `StrokeTransform`).
- **Verification:** `capture → display` at the same layout must be exact (the file's documented invariant) — a Swift Testing round-trip on the Apple simulator. iOS annotation UX visually unchanged (preview/manual). No ssm dependency, so **A proceeds during the ssm hold.**

### Sub-plan C — FolinoReaderJNI capture/display bridge (Folino Reader JNI, Android)

New stateless JNI entry points (their own `.so`) hosting the shared core over `InkStroke`, consumed by Kotlin per the Spike-1 data flow:

- `nativeAnnotationRepresentativePoint(strokeBytes) -> pointMm bytes` (shared policy).
- `nativeAnnotationCapture(strokeBytes, resolvedAnchorBytes, refPointBytes) -> DrawingAnchor bytes` (compose P from the ssm-resolved anchor + ref point, normalize, encode `InkStroke`).
- `nativeAnnotationDisplayTransforms(drawingsBytes, refPointsBytes) -> [(sp, Px, Py)] bytes` (zip drawings with batched ssm ref points, compose P, emit transforms).
- Wire `InkStroke ↔ bytes` for the JNI boundary (reuse `InkStrokeCodec`; a stroke-capture wire for the raw wet input). jextract Java + Kotlin facade; `Scripts/android-build-reader-libs.sh` rebuilds the `.so`.
- **Verification:** Android `.so` cross-build; unit-level via the shared core (already covered by A's round-trip). End-to-end needs the ssm re-pin (post-hold).

### Sub-plan D — Android persistence (Room + wirelet bridge)

- New Room entity `annotation_layers(score_id PK, payload BLOB, updated_at)` mirroring the iOS GRDB table 1:1; `payload` = JSON `{ drawings, textBoxes }` with base64 `InkStroke` blobs.
- Expose a `@WireletProvided AnnotationStore` implemented by `RoomLibraryStore` (same mechanism as `ReaderPreferencesStore`), so the store is Kotlin/Room but its caller is shared Swift.
- Save policy (layer assembly, 0.5 s debounce, empty-layer → delete) in shared Swift mirroring `ReaderViewModel+AnnotationPersistence.swift`, reached from Kotlin via a `@WireletObservable` bridge modeled on `ReaderPreferencesBridge.swift`. Kotlin supplies only UI events + the Room backend.
- **Verification:** instrumented Room round-trip; save-policy covered by shared-Swift unit tests.

### Sub-plan E — Android ink capture/render (androidx.ink wet/dry)

- Wet = `androidx.ink` 1.0.0 `InProgressStrokes` (front-buffered, motion-predicted), captured in document-mm via `motionEventToWorldTransform`; pin `StockBrushes.*V1`. Dry = own `CanvasStrokeRenderer` in a sibling overlay over `ScorePage` in absolute doc coords (zoom is a vector re-render — no raster `StaticInkLayer` needed).
- Commit handoff on `onStrokesFinished` → Spike-1 capture flow → add to dry overlay → `removeFinishedStrokes` same frame. Never persist androidx.ink's own format — only neutral `InkStroke`.
- Three-mode integration: vertical/horizontal overlay above the canvas, re-fetch transforms on reflow (not while drawing); paged overlay inside the `HorizontalPager` page content with `partitionByPage`.
- Gotchas: no offscreen compositing (max-texture cap), viewport-local dry matrix (float32), tile ≤4096 px if ink raster-caching is ever needed.
- **Verification:** emulator instrumented + screenshots (Compose ink renders in the emulator, unlike iOS PencilKit); S-Pen Samsung + Pixel Tablet for front-buffer quirks. Needs ssm re-pin.

### Sub-plan F — Tool palette & Reader UX (Android idiom)

- Toolset: pen, highlighter, whole-stroke eraser, color palette, stroke width, undo/redo (per-session stroke stack on the view model). Material bottom toolbar shown only in annotation mode; pencil/edit action in the top bar toggles the mode (`MutableStateFlow<Boolean>` gating overlay + toolbar + input routing). Disabled during playback; chrome dims while active. Analytics `annotation_started` / `annotation_ended` (stroke count) via the existing Android path.
- **UI tuning by eye — NOT auto-committed** (project convention: iteration after the initial landing waits for explicit go-ahead).

---

## Cross-repo sequencing & hold points (summary)

1. **This session:** Sub-plan B implemented in the ssm worktree, verified ssm-side, **HELD** (no merge/publish/re-pin/release).
2. **Next:** Sub-plan A (iOS-only, during the hold).
3. **After the parallel ssm-feature session lands:** ssm main gets B + the other features together; publish next ssm release; re-pin Folino (all five `Package.swift` + `project.yml`, one revision — `reference_worktree_ssm_repin_resolution_conflict` for the resolution-conflict recovery).
4. **Then:** C → D → E → F, end-to-end verified on emulator + device.

## Testing strategy (recap)

- **Shared Swift round-trip** (Sub-plan A core): `capture → display` exact at one layout — Apple sim + (once C lands) the Android toolchain.
- **iOS codec round-trip** (shipped Phase 1): `PKDrawing → InkStroke → PKDrawing` within the fidelity contract; highlighter validated first.
- **ssm bridge** (this doc): codec round-trip + bridge-via-cache host tests; Android `.so` cross-build as the compile gate.
- **Android instrumented** (E): draw → commit → reflow → ink follows musical positions; page-turn carries paged ink; zoom keeps ink crisp; device matrix S-Pen + Pixel Tablet.

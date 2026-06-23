# Pencil Annotation M2a — Vertical Musical Anchoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apple Pencil ink in the Vertical Reader pin to musical coordinates (measure + tick + staff, with sp offsets) and re-project to the current layout at render, replacing the M1 whole-canvas blob — so ink survives staff-size reflow and staff-visibility toggles.

**Architecture:** Two pure layout primitives are added upstream in `swift-sheet-music` (`SheetMusicLayout`): a **forward** `anchorReferencePoint` (musical coords → document point + sp) and a **continuous inverse** `resolveAnchor` (document point → musical coords). folino re-pins to the new ssm revision, then a pure `AnnotationAnchoring` maps each `PKStroke` ↔ `DrawingAnchor` via centroid anchoring + an affine normalize/denormalize transform (rigid translate + uniform scale). The Vertical container projects the model to the current layout off the scroll path; the ViewModel persists the per-stroke `[DrawingAnchor]` layer.

**Tech Stack:** Swift 6.3, iOS 26, PencilKit, `swift-sheet-music` (`SheetMusicLayout`/`SheetMusicCore`/`SheetMusicLayoutApple`/`SheetMusicUI`), GRDB (existing store), Swift Testing.

**Design spec:** [`docs/superpowers/specs/2026-06-24-pencil-annotation-m2-anchoring-policy-design.md`](../specs/2026-06-24-pencil-annotation-m2-anchoring-policy-design.md) (parent: [`2026-06-22-ipad-pencil-annotation-design.md`](../specs/2026-06-22-ipad-pencil-annotation-design.md)).

## Global Constraints

- **Two repos.** ssm dev clone: `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`. folino: `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`. Part A is ssm; Part B is folino. Part B is GATED on Part A being pushed to `origin/main` and re-pinned.
- **ssm push is human-gated.** Per the ssm workflow: verify in the example app → report → get explicit approval → push → re-pin folino. Never push ssm without approval (Task A4 is a STOP).
- **ssm pin is by `revision:` (full SHA), in FOUR files, all identical:** `project.yml`, `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/Reader/Package.swift`. Current SHA: `3f7884d7e70cb38376216a1983962716c3898c6a`.
- **New tests use Swift Testing** (`import Testing`, `@Test`, `#expect`).
- **ssm tests** run on macOS: `swift test --apple` (or `Scripts/preflight.sh --apple`). `SheetMusicLayout` has no dedicated filter; the new `AnchorPrimitivesTests` run under the full Apple suite. Guard tests with `#if os(macOS)` + `guard #available(macOS 15.0, *)`.
- **folino package tests** run via `xcodebuild test` on `platform=iOS Simulator,name=iPhone 17 Pro Max` (`swift test` is broken by the SwiftLint plugin). Verify the Reader package with its **own scheme**, not the app build (the app build increments-skips an edited package and false-SUCCEEDEDs).
- **Layout-building tests need the Apple font-metrics provider installed**, else `FontMetrics` precondition crashes. ssm tests use `TestSupport.installApple`; folino tests must install the equivalent from `SheetMusicLayoutApple` (Task B2 step 1 gives the discovery command).
- **No iOS simulator launch.** Stop at build-success (+ tests). Real ink/gesture/reflow behavior is verified by the user via a manual clean build (Task B5 hands off).
- **American English** in code/comments/commits; keep Apple's `cancelled` spelling for any `Task.isCancelled`-style identifiers.
- **Reader→`SheetMusicLayout` direct import is an allowed carve-out** (parent spec §10): the Reader already depends on `SheetMusicLayoutApple`/`SheetMusicUI`. Do not flag it as an architecture violation.
- **`MusicalAnchor` is unchanged** (already implemented, `max(0,…)`-clamped). This plan only populates it for real (M1 used an all-zero sentinel).

---

# PART A — Upstream ssm anchor primitives (`SheetMusicLayout`)

Work in the ssm repo. Recommended: a dedicated ssm worktree off `origin/main` (per the ssm worktree workflow); run `Scripts/link-apple-sounds.sh` after worktree setup. All paths below are under `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`.

## File Structure (Part A)

- Create: `Sources/SheetMusicLayout/Anchor/AnchorReferencePoint.swift` — forward primitive (`LayoutDocument.anchorReferencePoint(...)`) + the `measureLocalX(forTick:in:)` helper.
- Create: `Sources/SheetMusicLayout/Anchor/ResolveAnchor.swift` — `ResolvedAnchor` value type + continuous inverse (`LayoutDocument.resolveAnchor(at:)`) + its private selection helpers.
- Create: `Tests/SheetMusicTests/AnchorPrimitivesTests.swift` — forward, inverse, round-trip, nil-cases.
- Modify (verification only, revert before push): `Examples/Apple/SheetMusicExample/macOS/ContentViewMac.swift` — a temporary anchor-inspector overlay.

---

### Task A1: Forward primitive — `anchorReferencePoint`

**Files:**
- Create: `Sources/SheetMusicLayout/Anchor/AnchorReferencePoint.swift`
- Test: `Tests/SheetMusicTests/AnchorPrimitivesTests.swift`

**Interfaces:**
- Produces: `extension LayoutDocument { public func anchorReferencePoint(measureIndex: Int, tickInMeasure: Int, partIndex: Int, staffIndexInPart: Int) -> (point: CGPoint, sp: CGFloat)? }` and `static func measureLocalX(forTick: Int, in: LayoutMeasure) -> CGFloat`.
- Consumes (existing, verified verbatim): `LayoutSystem.{origin,size,measures,staffOrigins,sp}`, `LayoutSystem.flatIndex(for: StaffAddress) -> Int?`, `LayoutMeasure.{measureIndex,origin,width,tickColumns}`, `LayoutDocument.{systems,metrics}`, `StaffAddress(partIndex:staffIndexInPart:)`, `StaffMetrics.sp`.

- [ ] **Step 1: Write the failing test file with the forward tests**

Create `Tests/SheetMusicTests/AnchorPrimitivesTests.swift`:

```swift
#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("Anchor primitives")
    struct AnchorPrimitivesTests {
        private let _installApple = TestSupport.installApple

        @available(macOS 15.0, *)
        private func twoMeasureDoc() -> LayoutDocument {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .whole, notes: [note])
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff = Staff(measures: [measure, measure])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
            )
            return LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
        }

        @Test("anchorReferencePoint resolves measure/tick/staff to a document point")
        func forwardResolves() {
            guard #available(macOS 15.0, *) else { return }
            let doc = twoMeasureDoc()
            let ref = doc.anchorReferencePoint(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            )
            #expect(ref != nil)
            let system = doc.systems[0]
            let measure = system.measures.first { $0.measureIndex == 1 }!
            let expectedX = system.origin.x + measure.origin.x + (measure.tickColumns[0] ?? 0)
            let expectedY = system.origin.y + system.staffOrigins[0].y
            #expect(abs(ref!.point.x - expectedX) < 0.001)
            #expect(abs(ref!.point.y - expectedY) < 0.001)
            #expect(ref!.sp == doc.metrics.sp)
        }

        @Test("anchorReferencePoint returns nil for an out-of-range measure")
        func forwardNilMeasure() {
            guard #available(macOS 15.0, *) else { return }
            #expect(twoMeasureDoc().anchorReferencePoint(
                measureIndex: 99, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            ) == nil)
        }

        @Test("anchorReferencePoint returns nil for a missing staff")
        func forwardNilStaff() {
            guard #available(macOS 15.0, *) else { return }
            #expect(twoMeasureDoc().anchorReferencePoint(
                measureIndex: 0, tickInMeasure: 0, partIndex: 5, staffIndexInPart: 0,
            ) == nil)
        }
    }
#endif
```

- [ ] **Step 2: Run the tests to verify they fail (compile error: no `anchorReferencePoint`)**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music && swift test --apple 2>&1 | tail -30`
Expected: FAIL — `value of type 'LayoutDocument' has no member 'anchorReferencePoint'`.

- [ ] **Step 3: Implement the forward primitive**

Create `Sources/SheetMusicLayout/Anchor/AnchorReferencePoint.swift`:

```swift
import CoreGraphics
import SheetMusicCore

extension LayoutDocument {
    /// Document-space reference point for the `(measure, tick, staff)` part of a musical anchor: the x of the tick
    /// column (looked up / interpolated in the measure's `tickColumns`) at the y of the staff's top line, plus the
    /// layout's `sp`. The caller adds the anchor's `dxSp` / `verticalOffsetSp` (× `sp`) to reach the final ink origin.
    /// Returns `nil` when the measure or the staff is absent from this layout (out-of-range index, hidden staff) — the
    /// caller drops anchors that fail to resolve. Inverse: `resolveAnchor(at:)`.
    public func anchorReferencePoint(
        measureIndex: Int,
        tickInMeasure: Int,
        partIndex: Int,
        staffIndexInPart: Int,
    ) -> (point: CGPoint, sp: CGFloat)? {
        let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart)
        for system in systems {
            guard let measure = system.measures.first(where: { $0.measureIndex == measureIndex }) else {
                continue
            }
            guard let flat = system.flatIndex(for: address), flat < system.staffOrigins.count else {
                return nil
            }
            let localX = Self.measureLocalX(forTick: tickInMeasure, in: measure)
            let point = CGPoint(
                x: system.origin.x + measure.origin.x + localX,
                y: system.origin.y + system.staffOrigins[flat].y,
            )
            return (point, system.sp)
        }
        return nil
    }

    /// Measure-local x for a tick: exact `tickColumns` hit, else linear interpolation between the bracketing columns,
    /// else `0` (measure left edge) when the measure has no timed content. Mirrors the playback cursor's
    /// `beatXInMeasure` bracket logic so anchors and the cursor agree.
    static func measureLocalX(forTick tick: Int, in measure: LayoutMeasure) -> CGFloat {
        let columns = measure.tickColumns
        if let exact = columns[tick] { return exact }
        let sorted = columns.keys.sorted()
        guard let firstTick = sorted.first else { return 0 }
        var leftTick = firstTick
        var rightTick: Int?
        for t in sorted {
            if t <= tick { leftTick = t } else { rightTick = t; break }
        }
        guard let leftX = columns[leftTick] else { return 0 }
        if let rightTick, let rightX = columns[rightTick], rightTick > leftTick {
            let frac = CGFloat(tick - leftTick) / CGFloat(rightTick - leftTick)
            return leftX + frac * (rightX - leftX)
        }
        return leftX
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music && swift test --apple 2>&1 | tail -30`
Expected: PASS for the three `forward*` tests.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Sources/SheetMusicLayout/Anchor/AnchorReferencePoint.swift Tests/SheetMusicTests/AnchorPrimitivesTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(layout): add forward anchorReferencePoint primitive"
```

---

### Task A2: Continuous inverse — `resolveAnchor` + `ResolvedAnchor`

**Files:**
- Create: `Sources/SheetMusicLayout/Anchor/ResolveAnchor.swift`
- Test: `Tests/SheetMusicTests/AnchorPrimitivesTests.swift` (append)

**Interfaces:**
- Produces: `public struct ResolvedAnchor: Hashable, Sendable { measureIndex, tickInMeasure: Int; partIndex, staffIndexInPart: Int; dxSp, verticalOffsetSp: CGFloat }` and `extension LayoutDocument { public func resolveAnchor(at point: CGPoint) -> ResolvedAnchor? }`.
- Consumes: same layout types as A1, plus `LayoutSystem.staffAddresses: [StaffAddress]`. Selection logic mirrors `Sources/SheetMusicLayout/NearestCursor.swift` (verbatim system/staff/measure pickers).

- [ ] **Step 1: Write the failing inverse + round-trip tests**

Append inside the `AnchorPrimitivesTests` struct in `Tests/SheetMusicTests/AnchorPrimitivesTests.swift`:

```swift
        @Test("resolveAnchor recovers a clean anchor at a tick column")
        func inverseAtColumn() {
            guard #available(macOS 15.0, *) else { return }
            let doc = twoMeasureDoc()
            let ref = doc.anchorReferencePoint(
                measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            )!
            let r = doc.resolveAnchor(at: ref.point)
            #expect(r != nil)
            #expect(r!.measureIndex == 1)
            #expect(r!.tickInMeasure == 0)
            #expect(r!.partIndex == 0)
            #expect(r!.staffIndexInPart == 0)
            #expect(abs(r!.dxSp) < 0.001)
            #expect(abs(r!.verticalOffsetSp) < 0.001)
        }

        @Test("forward(resolve(point)) + offsets recovers the point (round-trip)")
        func roundTrip() {
            guard #available(macOS 15.0, *) else { return }
            let doc = twoMeasureDoc()
            let sp = doc.metrics.sp
            // Points built as known reference points plus an sp-sized offset (including above-staff, -2 sp).
            let cases: [(Int, Int, CGFloat, CGFloat)] = [(0, 0, 0, 0), (1, 0, 1.5, -2.0)]
            for (mi, tick, dx, vy) in cases {
                let ref = doc.anchorReferencePoint(
                    measureIndex: mi, tickInMeasure: tick, partIndex: 0, staffIndexInPart: 0,
                )!
                let p = CGPoint(x: ref.point.x + dx * sp, y: ref.point.y + vy * sp)
                let r = doc.resolveAnchor(at: p)!
                let ref2 = doc.anchorReferencePoint(
                    measureIndex: r.measureIndex, tickInMeasure: r.tickInMeasure,
                    partIndex: r.partIndex, staffIndexInPart: r.staffIndexInPart,
                )!
                let recovered = CGPoint(
                    x: ref2.point.x + r.dxSp * sp,
                    y: ref2.point.y + r.verticalOffsetSp * sp,
                )
                #expect(abs(recovered.x - p.x) < 0.01)
                #expect(abs(recovered.y - p.y) < 0.01)
            }
        }

        @Test("resolveAnchor returns nil for an empty document")
        func inverseNilEmpty() {
            guard #available(macOS 15.0, *) else { return }
            let empty = LayoutEngine.layout(score: Score(division: 480), options: .init(), availableWidth: 800)
            #expect(empty.resolveAnchor(at: .zero) == nil)
        }
```

- [ ] **Step 2: Run to verify failure (no `resolveAnchor`)**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music && swift test --apple 2>&1 | tail -30`
Expected: FAIL — `has no member 'resolveAnchor'`.

- [ ] **Step 3: Implement the inverse**

Create `Sources/SheetMusicLayout/Anchor/ResolveAnchor.swift`:

```swift
import CoreGraphics
import SheetMusicCore

/// Continuous musical position resolved from a document-space point — the inverse of `anchorReferencePoint`. Unlike
/// `nearestCursor`, it never snaps to a playable event and never returns `nil` for empty measures: it yields the
/// nearest tick column (or tick 0 at the measure's left edge in an empty measure) plus the sub-column residual in
/// `dxSp`, and a vertical offset from the staff top in `verticalOffsetSp`. The Reader maps it to a Domain
/// `MusicalAnchor`.
public struct ResolvedAnchor: Hashable, Sendable {
    public let measureIndex: Int
    public let tickInMeasure: Int
    public let partIndex: Int
    public let staffIndexInPart: Int
    public let dxSp: CGFloat
    public let verticalOffsetSp: CGFloat

    public init(
        measureIndex: Int, tickInMeasure: Int, partIndex: Int, staffIndexInPart: Int,
        dxSp: CGFloat, verticalOffsetSp: CGFloat,
    ) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
    }
}

extension LayoutDocument {
    /// Resolve a document-space point to a continuous `ResolvedAnchor`. Picks the nearest system (by y), the staff whose
    /// centerline is nearest (by y), and the nearest measure (by x); snaps the tick to the nearest tick column and
    /// stores the leftover horizontal distance in `dxSp` and the vertical distance from the staff top in
    /// `verticalOffsetSp`. Returns `nil` only when the layout has no systems / staves / measures. Forward:
    /// `anchorReferencePoint(...)`.
    public func resolveAnchor(at point: CGPoint) -> ResolvedAnchor? {
        guard let system = Self.chooseSystem(forY: point.y, in: systems) else { return nil }
        let sp = system.sp
        guard let flat = Self.chooseStaffIndex(forY: point.y, system: system, sp: sp),
              flat < system.staffAddresses.count, flat < system.staffOrigins.count else { return nil }
        let address = system.staffAddresses[flat]
        let staffTopY = system.origin.y + system.staffOrigins[flat].y
        let verticalOffsetSp = sp > 0 ? (point.y - staffTopY) / sp : 0
        guard let measure = Self.chooseMeasure(forX: point.x, system: system) else { return nil }
        let localX = point.x - system.origin.x - measure.origin.x
        let (tick, columnX) = Self.nearestTickColumn(toLocalX: localX, in: measure)
        let dxSp = sp > 0 ? (localX - columnX) / sp : 0
        return ResolvedAnchor(
            measureIndex: measure.measureIndex,
            tickInMeasure: tick,
            partIndex: address.partIndex,
            staffIndexInPart: address.staffIndexInPart,
            dxSp: dxSp,
            verticalOffsetSp: verticalOffsetSp,
        )
    }

    /// Tick column whose x is nearest `localX`; `(0, 0)` for an empty measure (anchor at the measure left edge).
    static func nearestTickColumn(toLocalX localX: CGFloat, in measure: LayoutMeasure) -> (tick: Int, columnX: CGFloat) {
        var best: (tick: Int, columnX: CGFloat, d: CGFloat)?
        for (tick, columnX) in measure.tickColumns {
            let d = abs(columnX - localX)
            if best.map({ d < $0.d }) ?? true { best = (tick, columnX, d) }
        }
        if let best { return (best.tick, best.columnX) }
        return (0, 0)
    }

    // Selection helpers mirror NearestCursor.swift (scoped as static methods to avoid touching that file).
    static func chooseSystem(forY y: CGFloat, in systems: [LayoutSystem]) -> LayoutSystem? {
        guard !systems.isEmpty else { return nil }
        if let containing = systems.first(where: { y >= $0.origin.y && y <= $0.origin.y + $0.size.height }) {
            return containing
        }
        return systems.min { systemVerticalDistance(y, $0) < systemVerticalDistance(y, $1) }
    }

    static func systemVerticalDistance(_ y: CGFloat, _ system: LayoutSystem) -> CGFloat {
        if y < system.origin.y { return system.origin.y - y }
        let bottom = system.origin.y + system.size.height
        if y > bottom { return y - bottom }
        return 0
    }

    static func chooseStaffIndex(forY y: CGFloat, system: LayoutSystem, sp: CGFloat) -> Int? {
        guard !system.staffOrigins.isEmpty else { return nil }
        return system.staffOrigins.indices.min { lhs, rhs in
            let midL = system.origin.y + system.staffOrigins[lhs].y + 2 * sp
            let midR = system.origin.y + system.staffOrigins[rhs].y + 2 * sp
            return abs(y - midL) < abs(y - midR)
        }
    }

    static func chooseMeasure(forX x: CGFloat, system: LayoutSystem) -> LayoutMeasure? {
        guard !system.measures.isEmpty else { return nil }
        if let containing = system.measures.first(where: { measure in
            let lo = system.origin.x + measure.origin.x
            return x >= lo && x <= lo + measure.width
        }) {
            return containing
        }
        return system.measures.min { measureHorizontalDistance(x, system, $0) < measureHorizontalDistance(x, system, $1) }
    }

    static func measureHorizontalDistance(_ x: CGFloat, _ system: LayoutSystem, _ measure: LayoutMeasure) -> CGFloat {
        let lo = system.origin.x + measure.origin.x
        let hi = lo + measure.width
        if x < lo { return lo - x }
        if x > hi { return x - hi }
        return 0
    }
}
```

- [ ] **Step 4: Run to verify all anchor tests pass**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music && swift test --apple 2>&1 | tail -30`
Expected: PASS for all `AnchorPrimitivesTests`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Sources/SheetMusicLayout/Anchor/ResolveAnchor.swift Tests/SheetMusicTests/AnchorPrimitivesTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(layout): add continuous resolveAnchor inverse primitive"
```

---

### Task A3: Full Apple preflight

**Files:** none (gate).

- [ ] **Step 1: Run the full Apple preflight to confirm no regressions**

Run: `cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music && Scripts/preflight.sh --apple 2>&1 | tail -40`
Expected: green (existing suite + the new `AnchorPrimitivesTests`). If red on pre-existing tests unrelated to anchoring, investigate before proceeding.

---

### Task A4: Example-app verification + human push gate

**Files:**
- Modify (temporary, revert after): `Examples/Apple/SheetMusicExample/macOS/ContentViewMac.swift`

This is a manual visual check (the ssm workflow requires example-app verification before push) + the mandatory human approval STOP.

- [ ] **Step 1: Add a temporary anchor-inspector overlay**

In `ContentViewMac.swift`, in the macOS tap handler that already receives a document-space point (`handleTap(at:document:)` per the example wiring), add a debug branch behind a local `@State private var anchorInspect = true`: on tap, call `document.resolveAnchor(at: point)`, then `document.anchorReferencePoint(measureIndex:tickInMeasure:partIndex:staffIndexInPart:)` on the result, compose `P = ref.point + (dxSp,vSp)*ref.sp`, and (a) print the `ResolvedAnchor`, (b) draw a small marker at `P`. Keep it minimal — one overlay dot + a `Text` of the resolved fields.

- [ ] **Step 2: Regenerate and build the macOS example**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple && xcodegen
xcodebuild -project /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample.xcodeproj -scheme SheetMusicExampleMac -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the example and visually verify**

`open` the built `.app` (from the `xcodebuild` products dir). Load a multi-staff score. Tap several points (on a note, in trailing whitespace, above the top staff, between two staves). Confirm: the marker `P` lands on the tapped point (round-trip is tight); the resolved `measureIndex`/`staff` match the tapped location; `verticalOffsetSp` is negative above the staff.

- [ ] **Step 4: Revert the temporary overlay; commit nothing extra**

Remove the inspector edit from `ContentViewMac.swift` (and re-`xcodegen` is not needed for source-only revert). Confirm `git status` shows only the two primitive source files + the test as the branch's changes.

- [ ] **Step 5: STOP — report and request approval to push ssm**

Post a short report to the user: what was added (forward/inverse + tests), preflight result, example-app verification result. **Do not push without explicit approval** (per the ssm workflow). Wait for "OK to push."

- [ ] **Step 6: After approval — push ssm and capture the new SHA**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music push origin HEAD:main
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music rev-parse HEAD
```

Record the printed SHA — it is the re-pin target for Task B1.

---

# PART B — folino Reader integration (Vertical only)

Work in the folino repo (recommended: a folino worktree off local `main`, with `Config/Local.xcconfig` symlinked). All paths below are under `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`. **Gated on Part A being pushed.**

## File Structure (Part B)

- Modify: `project.yml`, `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/Reader/Package.swift` — re-pin ssm SHA.
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchorPolicy.swift` — the swappable representative-point seam (centroid).
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift` — capture/display transform math + `PKDrawing` assembly.
- Create: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift` — pure transform/anchor math tests.
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — `annotationDrawings: [DrawingAnchor]` state + pending fields.
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+AnnotationPersistence.swift` — per-stroke load/save/debounce; drop the sentinel.
- Modify: `Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift` — to the `[DrawingAnchor]` API.
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift` — spec carries a `PKDrawing` to seed + emits the live `PKDrawing`.
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift` — capture on change, project model off the scroll path, reseed on reflow.

---

### Task B1: Re-pin folino to the new ssm SHA

**Files:** `project.yml`, `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/Reader/Package.swift`.

- [ ] **Step 1: Replace the old SHA with the new one in all four files**

Replace `3f7884d7e70cb38376216a1983962716c3898c6a` with the SHA from Task A4 Step 6 in each file. Use four explicit edits (whole-line), one per file — do not hand-edit partially.

- [ ] **Step 2: Regenerate the Xcode project**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS && xcodegen generate`
Expected: regenerates `Folino.xcodeproj`, resolving the new ssm revision.

- [ ] **Step 3: Verify the Reader package still builds against the new pin**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, with `Compiling` lines for the Reader sources (proves it really compiled, not increment-skipped).

- [ ] **Step 4: Commit the re-pin**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS add project.yml Packages/Domain/Package.swift Packages/Infrastructure/Package.swift Packages/Features/Reader/Package.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS commit -m "chore(deps): re-pin swift-sheet-music for anchor primitives"
```

---

### Task B2: `AnnotationAnchoring` capture/display math (pure)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchorPolicy.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift`

**Interfaces:**
- Produces:
  - `enum AnnotationAnchorPolicy { static func representativePoint(of stroke: PKStroke) -> CGPoint }`
  - `enum AnnotationAnchoring { static func anchorPoint(for: MusicalAnchor, in: LayoutDocument) -> (point: CGPoint, sp: CGFloat)?; static func normalizeTransform(forCentroid: CGPoint, in: LayoutDocument) -> (anchor: MusicalAnchor, transform: CGAffineTransform)?; static func displayTransform(for: MusicalAnchor, in: LayoutDocument) -> CGAffineTransform?; static func capture(strokes: [PKStroke], in: LayoutDocument) -> [DrawingAnchor]; static func display(_ drawings: [DrawingAnchor], in: LayoutDocument) -> PKDrawing }`
- Consumes: `LayoutDocument.{anchorReferencePoint,resolveAnchor}` (Part A), `Domain.{MusicalAnchor,DrawingAnchor}`, PencilKit `PKStroke`/`PKDrawing`.

- [ ] **Step 1: Find the Apple font-metrics install symbol for layout-building tests**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS && grep -rn "install" Packages/Features/Reader/Tests Packages/Features/Reader/Sources | grep -i "layout\|apple\|metrics" | head`
Also: `grep -rn "public" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicLayoutApple | grep -i "install\|register\|provider" | head`
Use the public install entry point you find (the ssm tests use the internal `TestSupport.installApple`; the public equivalent lives in `SheetMusicLayoutApple`). Call it once in the test type's init (as a stored `private let _install = …`). If `LayoutEngine.layout` already renders without it in the Reader test target, skip — but the precondition crash means you almost certainly need it.

- [ ] **Step 2: Write the failing pure-math tests**

Create `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift`:

```swift
import CoreGraphics
import Domain
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite("AnnotationAnchoring")
struct AnnotationAnchoringTests {
    // NOTE: add the Apple font-metrics install from Task B2 Step 1 here, e.g.:
    // private let _install = SheetMusicLayoutApple.<installEntryPoint>

    private func doc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        var options = LayoutOptions()
        options.staffSize = staffSize
        return LayoutEngine.layout(score: score, options: options, availableWidth: 800)
    }

    @Test("anchorPoint composes the forward reference with the anchor's sp offsets")
    func anchorPointComposes() {
        let d = doc()
        let anchor = MusicalAnchor(
            measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 1.5, verticalOffsetSp: -2.0,
        )
        let ref = d.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)!
        let p = AnnotationAnchoring.anchorPoint(for: anchor, in: d)!
        #expect(abs(p.point.x - (ref.point.x + 1.5 * ref.sp)) < 0.001)
        #expect(abs(p.point.y - (ref.point.y - 2.0 * ref.sp)) < 0.001)
        #expect(p.sp == ref.sp)
    }

    @Test("normalize then display transform is identity at the same layout")
    func roundTripIdentity() {
        let d = doc()
        let centroid = d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)!.point
        let (anchor, normalize) = AnnotationAnchoring.normalizeTransform(forCentroid: centroid, in: d)!
        let display = AnnotationAnchoring.displayTransform(for: anchor, in: d)!
        let round = normalize.concatenating(display)
        // a sample document point maps back to itself
        let sample = CGPoint(x: centroid.x + 30, y: centroid.y - 12)
        let mapped = sample.applying(round)
        #expect(abs(mapped.x - sample.x) < 0.01)
        #expect(abs(mapped.y - sample.y) < 0.01)
    }

    @Test("staff-size doubling doubles the display scale")
    func scaleWithStaffSize() {
        let small = doc(staffSize: 20)
        let large = doc(staffSize: 40)
        let centroid = small.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)!.point
        let (anchor, _) = AnnotationAnchoring.normalizeTransform(forCentroid: centroid, in: small)!
        let dSmall = AnnotationAnchoring.displayTransform(for: anchor, in: small)!
        let dLarge = AnnotationAnchoring.displayTransform(for: anchor, in: large)!
        // scale component a doubles (sp 5 -> 10)
        #expect(abs(dLarge.a - 2 * dSmall.a) < 0.001)
    }
}
```

- [ ] **Step 3: Run to verify failure (no `AnnotationAnchoring`)**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring 2>&1 | tail -30`
Expected: FAIL — `cannot find 'AnnotationAnchoring' in scope`.

- [ ] **Step 4: Implement the policy seam**

Create `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchorPolicy.swift`:

```swift
import CoreGraphics
import PencilKit

/// Chooses the single document-space point a stroke is anchored to. v1 = the stroke's bounding-box center (centroid):
/// direction-independent, lands a circle's anchor on the note it encircles, and splits any rigid-reflow overhang to
/// both sides of center. Isolated here so the heuristic (leading point, nearest-note snapping, …) can change later
/// WITHOUT changing the stored format — the anchor is always a `MusicalAnchor`, so existing ink stays compatible.
enum AnnotationAnchorPolicy {
    static func representativePoint(of stroke: PKStroke) -> CGPoint {
        let b = stroke.renderBounds
        return CGPoint(x: b.midX, y: b.midY)
    }
}
```

- [ ] **Step 5: Implement the anchoring math**

Create `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift`:

```swift
import CoreGraphics
import Domain
import PencilKit
import SheetMusicLayout

/// Maps freehand `PKStroke`s to/from musical anchors against a layout. Capture: each stroke -> one `DrawingAnchor`
/// whose `MusicalAnchor` is the centroid's resolved musical position and whose `encodedDrawing` is the single stroke
/// normalized to (origin = the resolved anchor point `P`, unit = the capture layout's `sp`). Display: project each
/// stored stroke to the CURRENT layout (× current `sp`, + current `P`). Reflow is therefore a pure translate + uniform
/// scale; round-trip at the same layout is exact.
enum AnnotationAnchoring {
    /// Resolved anchor point `P` (forward reference + the anchor's sp offsets) and the layout `sp`. `nil` when the
    /// forward primitive can't resolve the anchor in this layout (out-of-range measure, hidden staff).
    static func anchorPoint(for anchor: MusicalAnchor, in document: LayoutDocument) -> (point: CGPoint, sp: CGFloat)? {
        guard let ref = document.anchorReferencePoint(
            measureIndex: anchor.measureIndex,
            tickInMeasure: anchor.tickInMeasure,
            partIndex: anchor.partIndex,
            staffIndexInPart: anchor.staffIndexInPart,
        ) else { return nil }
        let point = CGPoint(
            x: ref.point.x + CGFloat(anchor.dxSp) * ref.sp,
            y: ref.point.y + CGFloat(anchor.verticalOffsetSp) * ref.sp,
        )
        return (point, ref.sp)
    }

    /// Capture transform: resolves `centroid` to a `MusicalAnchor` and returns the document→normalized affine
    /// (translate by `-P`, then scale by `1/sp`). `nil` when the centroid can't be resolved or `sp <= 0`.
    static func normalizeTransform(
        forCentroid centroid: CGPoint, in document: LayoutDocument,
    ) -> (anchor: MusicalAnchor, transform: CGAffineTransform)? {
        guard let resolved = document.resolveAnchor(at: centroid) else { return nil }
        let anchor = MusicalAnchor(
            measureIndex: resolved.measureIndex,
            tickInMeasure: resolved.tickInMeasure,
            partIndex: resolved.partIndex,
            staffIndexInPart: resolved.staffIndexInPart,
            dxSp: Double(resolved.dxSp),
            verticalOffsetSp: Double(resolved.verticalOffsetSp),
        )
        guard let (point, sp) = anchorPoint(for: anchor, in: document), sp > 0 else { return nil }
        let transform = CGAffineTransform(translationX: -point.x, y: -point.y)
            .concatenating(CGAffineTransform(scaleX: 1 / sp, y: 1 / sp))
        return (anchor, transform)
    }

    /// Display transform: normalized→document affine for `anchor` in the current layout (scale by `sp`, then translate
    /// by `P`). `nil` when the anchor can't be resolved or `sp <= 0`.
    static func displayTransform(for anchor: MusicalAnchor, in document: LayoutDocument) -> CGAffineTransform? {
        guard let (point, sp) = anchorPoint(for: anchor, in: document), sp > 0 else { return nil }
        return CGAffineTransform(scaleX: sp, y: sp)
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }

    /// Re-anchor every live stroke against the current layout. Strokes whose centroid can't resolve are dropped.
    static func capture(strokes: [PKStroke], in document: LayoutDocument) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            let centroid = AnnotationAnchorPolicy.representativePoint(of: stroke)
            guard let (anchor, normalize) = normalizeTransform(forCentroid: centroid, in: document) else { return nil }
            var normalized = stroke
            normalized.transform = stroke.transform.concatenating(normalize)
            let data = PKDrawing(strokes: [normalized]).dataRepresentation()
            return DrawingAnchor(anchor: anchor, encodedDrawing: data)
        }
    }

    /// Project the stored model to the current layout as one canvas `PKDrawing`. Anchors that fail to resolve
    /// (out-of-range measure, hidden staff) are skipped (and pruned on the next save by the caller).
    static func display(_ drawings: [DrawingAnchor], in document: LayoutDocument) -> PKDrawing {
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard let denormalize = displayTransform(for: drawing.anchor, in: document) else { continue }
            guard let stored = try? PKDrawing(data: drawing.encodedDrawing), let s0 = stored.strokes.first else { continue }
            var s = s0
            s.transform = s0.transform.concatenating(denormalize)
            strokes.append(s)
        }
        return PKDrawing(strokes: strokes)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring 2>&1 | tail -30`
Expected: PASS (3 tests). If `LayoutOptions.staffSize` is named differently, fix the test's option-setting to match the real `LayoutOptions` field (grep `LayoutOptions` in ssm).

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS add Packages/Features/Reader/Sources/Reader/Annotation Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS commit -m "feat(reader): add musical anchoring capture/display math"
```

---

### Task B3: ViewModel — per-stroke model + persistence

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (annotation state, ~lines 37-42, 74, 87)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+AnnotationPersistence.swift` (full rewrite of the extension)
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift` (update to the `[DrawingAnchor]` API)

**Interfaces:**
- Produces on `ReaderViewModel`: `var annotationDrawings: [DrawingAnchor]`; `func loadAnnotations() async`; `func annotationDrawingsDidChange(_ drawings: [DrawingAnchor])`; `func flushPendingAnnotationSave() async`.
- Removes: `annotationDrawingData: Data?`, `makeSentinelAnchor()`, `pendingAnnotationData`, `pendingAnnotationIsEmpty`.

- [ ] **Step 1: Update the persistence tests to the new API (red)**

In `Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift`, replace the three tests' bodies to drive `[DrawingAnchor]`. Use a real anchor (not the removed sentinel):

```swift
    private static func anchor() -> MusicalAnchor {
        MusicalAnchor(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0)
    }

    @Test func loadsPersistedDrawingsIntoTheObservableProperty() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let drawings = [DrawingAnchor(anchor: Self.anchor(), encodedDrawing: Data([0x01, 0x02]))]
        try await store.saveAnnotationLayer(AnnotationLayer(
            scoreItemID: scoreID, drawings: drawings, textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        ))
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        await vm.loadAnnotations()
        #expect(vm.annotationDrawings == drawings)
    }

    @Test func debouncedChangePersistsOneLayerWithTheDrawings() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        let drawings = [DrawingAnchor(anchor: Self.anchor(), encodedDrawing: Data([0xAA]))]
        vm.annotationDrawingsDidChange(drawings)
        await vm.flushPendingAnnotationSave()
        let saved = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(saved?.drawings == drawings)
        #expect(await store.saveCount == 1)
    }

    @Test func emptyDrawingsDeletesTheLayer() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        try await store.saveAnnotationLayer(AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(anchor: Self.anchor(), encodedDrawing: Data([0x01]))],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        ))
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        vm.annotationDrawingsDidChange([])
        await vm.flushPendingAnnotationSave()
        #expect(try await store.annotationLayer(forScoreItem: scoreID) == nil)
        #expect(await store.deleteCount == 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationPersistenceTests 2>&1 | tail -30`
Expected: FAIL — `annotationDrawings` / `annotationDrawingsDidChange` not found.

- [ ] **Step 3: Update the ViewModel's annotation state**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, replace the `annotationDrawingData` declaration (and its `pendingAnnotationData` / `pendingAnnotationIsEmpty` companions) with:

```swift
    /// The score's annotation model: one `DrawingAnchor` per stroke, each pinned to a `MusicalAnchor`. Loaded on open,
    /// rewritten on every canvas change. The container projects this to the current layout for display.
    var annotationDrawings: [DrawingAnchor] = []

    var pendingAnnotationDrawings: [DrawingAnchor]?
```

(Keep `isAnnotating`, `annotationStore`, `annotationSaveTask` as they are.)

- [ ] **Step 4: Rewrite the persistence extension**

Replace the entire body of `Packages/Features/Reader/Sources/Reader/ReaderViewModel+AnnotationPersistence.swift`:

```swift
import Domain
import Foundation

// MARK: - Annotation persistence (M2 — per-stroke musical anchoring)

extension ReaderViewModel {
    /// Loads any persisted annotation layer for the current score into `annotationDrawings`. Called from `load()` once
    /// the score and preferences are ready.
    func loadAnnotations() async {
        let layer = try? await annotationStore.annotationLayer(forScoreItem: scoreItem.id)
        annotationDrawings = layer?.drawings ?? []
    }

    /// Called by the container on every canvas change with the freshly re-anchored drawings. Updates the in-memory
    /// model immediately (so a re-render projects the live ink, not a stale model) and debounces a save ~0.5 s; an
    /// empty model deletes the layer instead of storing an empty one.
    func annotationDrawingsDidChange(_ drawings: [DrawingAnchor]) {
        annotationDrawings = drawings
        pendingAnnotationDrawings = drawings
        annotationSaveTask?.cancel()
        let scoreID = scoreItem.id
        annotationSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            if Task.isCancelled { return }
            await self?.persistPendingAnnotation(scoreID: scoreID)
        }
    }

    /// Writes (or deletes) the pending model immediately. Safe when nothing is pending. Called before `advance` swaps
    /// the score and on VM teardown so no ink is lost mid-transition.
    func flushPendingAnnotationSave() async {
        annotationSaveTask?.cancel()
        annotationSaveTask = nil
        await persistPendingAnnotation(scoreID: scoreItem.id)
    }

    private func persistPendingAnnotation(scoreID: Domain.ScoreItemID) async {
        guard let drawings = pendingAnnotationDrawings else { return }
        pendingAnnotationDrawings = nil
        if drawings.isEmpty {
            try? await annotationStore.deleteAnnotationLayer(forScoreItem: scoreID)
            return
        }
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: drawings,
            textBoxes: [],
            updatedAt: Date(),
        )
        try? await annotationStore.saveAnnotationLayer(layer)
    }
}
```

- [ ] **Step 5: Run the persistence tests to verify they pass**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationPersistenceTests 2>&1 | tail -30`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Sources/Reader/ReaderViewModel+AnnotationPersistence.swift Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS commit -m "feat(reader): persist per-stroke annotation drawings (drop M1 sentinel blob)"
```

---

### Task B4: Canvas spec — seed a `PKDrawing`, emit the live `PKDrawing`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift` (the `AnnotationOverlaySpec` type + `AnnotationCanvasController.update`/`applyDrawing`/`canvasViewDrawingDidChange`)

**Interfaces:**
- `AnnotationOverlaySpec` changes from `drawingData: Data?` + `onChange: (Data, Bool) -> Void` to `displayDrawing: PKDrawing` + `onChange: (PKDrawing) -> Void`.

- [ ] **Step 1: Change the spec fields**

In `AnnotationCanvasView.swift`, in `AnnotationOverlaySpec`, replace `drawingData`/`onChange` with:

```swift
    /// The model projected to the current layout (Task B2 `display(...)`). The controller seeds the canvas with this
    /// whenever it changes — on load and on reflow — guarded against echoing the user's own in-progress ink.
    let displayDrawing: PKDrawing
    /// Emits the canvas's live drawing on every change; the container re-anchors its strokes and persists.
    let onChange: (PKDrawing) -> Void
```

- [ ] **Step 2: Update the controller's change callback to emit the drawing**

Replace `canvasViewDrawingDidChange`:

```swift
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        lastSeededDrawing = canvasView.drawing // our own edit is the source of truth; don't let applyDrawing echo it
        onChange(canvasView.drawing)
    }
```

- [ ] **Step 3: Update seeding to accept a `PKDrawing`**

Replace `onChange`/`state` capture in `update(spec:scroll:pinch:)` to store `onChange = spec.onChange` (now `(PKDrawing) -> Void`) and call a new `applyDrawing(spec.displayDrawing)`; replace `applyDrawing(_:)` and the `lastLoadedData`/`lastSeededDrawing` field:

```swift
    private var lastSeededDrawing = PKDrawing()

    /// Seed/replace the canvas only when the projected model actually changed (load or reflow); never echo the user's
    /// own in-progress edits back onto the canvas.
    private func applyDrawing(_ drawing: PKDrawing) {
        guard let canvas else { return }
        if drawing.dataRepresentation() != lastSeededDrawing.dataRepresentation() {
            lastSeededDrawing = drawing
            if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
                canvas.drawing = drawing
            }
        }
    }
```

Update the `onChange` stored-property type to `(PKDrawing) -> Void` (default `{ _ in }`), and ensure `update(...)` calls `applyDrawing(spec.displayDrawing)` after assigning state.

- [ ] **Step 4: Build the Reader package to verify it compiles**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation 2>&1 | tail -20`
Expected: BUILD SUCCEEDED (the container won't compile yet if it still passes `drawingData`; if so, this step fails at the container — proceed to Task B5 which fixes the container, then re-run). To keep this task self-contained, temporarily satisfy the container call site in B5.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS add Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS commit -m "feat(reader): canvas seeds a projected PKDrawing and emits the live drawing"
```

---

### Task B5: Container wiring — capture on change, project off the scroll path, reseed on reflow

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift` (`annotationSpec`, plus a projected-drawing `@State` and reprojection on `document` / `annotationDrawings` change)

**Interfaces:**
- Consumes: `AnnotationAnchoring.capture(strokes:in:)`, `AnnotationAnchoring.display(_:in:)`, `viewModel.annotationDrawings`, `viewModel.annotationDrawingsDidChange(_:)`, `self.document`, `self.score`.

- [ ] **Step 1: Add projected-drawing state + a reprojection helper**

In `VerticalScoreContainer`, add near the other `@State`:

```swift
    /// The annotation model projected to the current layout. Recomputed only when `document` or the model changes —
    /// NOT on scroll/pinch — so per-tick rendering stays cheap. Passed to the canvas as the seed drawing.
    @State private var projectedAnnotations = PKDrawing()
```

Add a helper:

```swift
    private func reprojectAnnotations() {
        guard let doc = document else { projectedAnnotations = PKDrawing(); return }
        projectedAnnotations = AnnotationAnchoring.display(viewModel.annotationDrawings, in: doc)
    }
```

- [ ] **Step 2: Recompute the projection on the right triggers (not on scroll)**

On the same view that owns `document`, add:

```swift
        .onChange(of: document) { _, _ in reprojectAnnotations() }
        .onChange(of: viewModel.annotationDrawings) { _, _ in reprojectAnnotations() }
        .onAppear { reprojectAnnotations() }
```

(`viewModel.annotationDrawings` is `Equatable` via `[DrawingAnchor]`, so `onChange` fires on load and after a save round-trip. Scroll/pinch do not change `document`, so they never trigger reprojection.)

- [ ] **Step 3: Rewire `annotationSpec` to the new spec + capture**

Replace the `annotationSpec(viewport:)` body's spec construction:

```swift
    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                guard let doc = document else { return }
                viewModel.annotationDrawingsDidChange(
                    AnnotationAnchoring.capture(strokes: drawing.strokes, in: doc),
                )
            },
            state: { annotationCanvasState(viewport: viewport) },
        )
    }
```

- [ ] **Step 4: Build the Reader package**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation 2>&1 | tail -20`
Expected: BUILD SUCCEEDED with `Compiling VerticalScoreContainer.swift`.

- [ ] **Step 5: Run the full Reader test suite**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | tail -30`
Expected: all Reader tests pass (anchoring + persistence + pre-existing).

- [ ] **Step 6: Build the whole app to confirm integration**

Run: `cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS && xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS add Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS commit -m "feat(reader): anchor ink per stroke and reproject on reflow (Vertical)"
```

- [ ] **Step 8: Hand off to the user for manual device verification**

Per the no-simulator-launch rule, do NOT drive the simulator. Tell the user to clean-build on device/simulator and check, with Apple Pencil in Vertical mode: (a) draw a circle around a note, a fingering above a note, an underline under a passage; (b) change staff size — ink scales and stays on its music; (c) toggle a staff's visibility — ink on it disappears and returns; (d) reopen the score — ink reloads in the same musical positions; (e) draw a span mark across a line break, change staff size — confirm the documented rigid-overhang degradation is acceptable. Report back the "feel" of the centroid heuristic (the swappable seam exists if it needs to change).

---

## Self-Review

**Spec coverage** (`2026-06-24-…-anchoring-policy-design.md`):
- §2 tick-grid target → A1/A2 primitives, B2 capture maps `ResolvedAnchor`→`MusicalAnchor`. ✓
- §2/§3.2 one rigid anchor per stroke → B2 `capture` (one `DrawingAnchor`/stroke), affine normalize/denormalize (translate + uniform scale). ✓
- §3.3 centroid + swappable seam → B2 `AnnotationAnchorPolicy.representativePoint`. ✓
- §3.4 nearest-staff-by-centerline + signed sp offset → A2 `chooseStaffIndex` (centerline) + `verticalOffsetSp`. ✓
- §4 capture/display with `P = forward + offsets·sp`, round-trip exact → B2 `anchorPoint`/`normalizeTransform`/`displayTransform` + `roundTripIdentity` test. ✓
- §4.3 reflow scales by `newSp/oldSp` → B5 reproject on `document` change; `scaleWithStaffSize` test. ✓
- §5 invalidation: forward-nil ⇒ not rendered, pruned on save; staff-visibility same path → B2 `display` skips nil; B3 empty/`compactMap` drop persists the surviving set. ✓
- §6 upstream forward/inverse → Part A. ✓
- §7 M2a Vertical only → Part B touches only Vertical; Horizontal/Paged untouched. ✓
- §8 amends parent §4.4/§11 leading-point → centroid → B2. ✓
- §9 testing (round-trip, scale, invalidation) → A2/B2 tests; PKStroke-level + visual behavior → B5 manual hand-off (no-simulator rule). ✓

**Placeholder scan:** Two items are intentionally local-confirm, with discovery commands, not placeholders: the `SheetMusicLayoutApple` install symbol (B2 Step 1 greps for it) and the `LayoutOptions` staff-size field name (B2 Step 6 notes the grep). PKStroke-geometry validation is deliberately manual (B5) because constructing `PKStrokePoint`s in unit tests is SDK-fragile; the affine math it relies on IS unit-tested in B2.

**Type consistency:** `anchorReferencePoint` returns `(point:CGPoint, sp:CGFloat)?` everywhere (A1, B2). `resolveAnchor`→`ResolvedAnchor` (CGFloat offsets) mapped to `MusicalAnchor` (Double) in B2. `AnnotationOverlaySpec.{displayDrawing:PKDrawing, onChange:(PKDrawing)->Void}` consistent across B4/B5. VM API `annotationDrawings`/`annotationDrawingsDidChange`/`loadAnnotations`/`flushPendingAnnotationSave` consistent across B3/B5 and tests.

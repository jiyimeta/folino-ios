# iPad Apple Pencil Annotation — Design

- **Status:** Draft for review
- **Date:** 2026-06-22
- **Scope:** v1 free-hand drawing annotation layer for the Reader, anchored to musical coordinates, persisted locally and synced via CloudKit.
- **Implementation:** decomposed into **three plans** (see §16); this is one design doc, three writing-plans cycles.

## 1. Goal

Let users mark up a score with free-hand ink — Apple Pencil on iPad as the primary input, finger as the fallback — such that the marks belong to the *music*, not the *page*. A circle drawn around measure 5 stays on measure 5 through scroll, viewport (pinch) zoom, staff-visibility toggles, **and** staff-size changes that reflow the layout. Marks persist locally and follow the user's iCloud account to their other devices.

This realizes the long-standing product intent already written into the product docs (`vision.md` principle 5, `features.md` "Annotations", `feasibility.md` D3 / O3, `architecture.md` data model) and partially scaffolded in Domain.

## 2. Scope

### In scope (v1)

1. **Free-hand drawing only.** One ink layer per score. Standard PencilKit tool palette (`PKToolPicker`) — pen, pencil, marker, eraser, lasso, ruler, color, undo/redo. folino does not skin or replace it.
2. **Input model:**
   - iPad with a paired Apple Pencil → **Pencil draws, finger scrolls/zooms** (`PKCanvasView.drawingPolicy = .pencilOnly`).
   - No Pencil (iPad without a paired Pencil, or iPhone) → **one finger draws, two fingers scroll/zoom** (`drawingPolicy = .anyInput`), matching Photos Markup / Freeform. No explicit "draw mode" toggle (see §6 for the fallback if the arbitration spike fails).
3. **Reflow-stable anchoring (decision "B").** Ink is pinned to **musical coordinates** (measure + tick for x; staff + staff-space offset for y), re-projected to the current layout at render. Survives staff-size (content-zoom) changes, not just viewport zoom. (§4)
4. **Canvas hosting "A1".** The `PKCanvasView` rides the *existing* Reader scroll/zoom transform as a child of the transformed content subtree — no second implementation of the pinch/scroll/zoom position math. (§5)
5. **Local persistence** via a new `LiveAnnotationStore` (SQLite). (§7)
6. **CloudKit Private DB sync** of the annotation layer — the first concrete implementation behind the existing `CloudSync` protocol. (§8)
7. **Library annotation indicator** — a score that has ink shows a marker in the library list. (§9)

**Platform note (iPhone):** the input model covers iPhone (one-finger draw), but v1 **QA targets iPad**; iPhone annotation is **best-effort** (functional, not a dedicated test/polish target). Phone-screen ergonomics of ink are out of v1 scope.

### Out of scope (deferred)

- **Text boxes.** The Domain model already includes `TextBoxAnchor`; v1 ships drawing only. Text boxes are a clean follow-on reusing the same anchoring + persistence + sync.
- **PDF underlay annotation** (post-v1 PDF import draws on the same layer — `roadmap.md`).
- **Android annotation.** PencilKit is Apple-only. The *anchor model*, the *anchor↔document mapping*, and persistence/sync *envelope* semantics are platform-neutral and shareable (§10), but no Android drawing UI in this work. **Cross-platform ink interop is explicitly out of scope:** the stored `PKDrawing` blob is Apple-proprietary binary; it rides the shared sync envelope as iOS-only payload. An interoperable stroke representation for Android is future work.
- **Multi-measure stroke stretching across a line break.** A single stroke anchors to one measure and translates rigidly on reflow; it does not bend to follow measures that reflow onto different lines (§4.4 graceful-degradation note).
- **Annotation in Picture-in-Picture** score display.
- **Rich text / formatted annotations.**
- **Per-stroke CloudKit conflict merge.** v1 sync is last-writer-wins on the whole layer (§8).
- **Anchor stability under structural score edits.** The Editor is a stub today; measure insert/delete that would shift `measureIndex` is not in v1. v1 only defines a defensive policy for out-of-range anchors (§13).

## 3. Background — current state

**Domain — scaffolded but `internal` (needs a public-API surfacing pass, see §10):**

- `AnnotationLayer` (id, scoreItemID, `drawings: [DrawingAnchor]`, `textBoxes: [TextBoxAnchor]`, updatedAt) — `Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift`.
- `DrawingAnchor` (id, anchor, `encodedDrawing: Data` — an opaque `PKDrawing`; Domain does not import PencilKit).
- `TextBoxAnchor` (id, anchor, text).
- `MusicalAnchor` + `UnitRect` — `Packages/Domain/Sources/Domain/MusicalAnchor.swift`. **The current `MusicalAnchor(systemIndex, normalizedFrame)` is replaced in v1; `UnitRect` is removed (§4).**
- `AnnotationStore` protocol (CRUD by score id) — `Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift`.
- ID types `AnnotationID` / `AnnotationLayerID` — `Packages/Domain/Sources/Domain/IDs.swift` (currently `internal` and **not** `Sendable`, unlike `public struct ScoreItemID`).
- **All of the above are `internal`** — exercised only via `@testable import Domain`. They must be promoted to `public` (with `public init`s and `Sendable` on the ID types) before Infrastructure can implement `AnnotationStore` and the Reader can consume the models. This is real work, not "complete".
- **Tests (three files, all touched by the §4 change):** `AnnotationLayerTests` (Codable round-trip), `StorageProtocolsTests` (`FakeAnnotationStore` + CRUD contract), and `MusicalAnchorTests` (which tests the **old** `systemIndex`/`normalizedFrame` shape and a `UnitRectTests` suite — both rewritten/removed under §4).

**Not built (this work):**

- Concrete `LiveAnnotationStore` + SQLite schema/migration (nothing in `Packages/Infrastructure/Sources/Persistence`; current migrations are v1…v11, no `annotation_layers` table).
- Any Reader integration (no canvas hosting, no musical-position ↔ layout-rect mapping in the Reader).
- CloudSync **implementation** (`Packages/Infrastructure/Sources/CloudSync` is a placeholder; the Domain `CloudSync` protocol already exists and is `public`).

**Core principle (unchanged):** annotations belong to music, not pages (`vision.md` #5). The whole anchoring design exists to honor this.

## 4. Anchoring model (decision B)

### 4.1 The problem this solves

Two kinds of zoom exist in the Reader and they behave differently:

- **Viewport zoom (pinch)** — a `.scaleEffect`; never re-runs layout. Ink scales with the score for free.
- **Content zoom (staff size, e.g. 14 → 18 pt)** — re-runs `LayoutEngine.layout`, changing how many measures fit per line, i.e. **line breaks and page count change**. A given measure moves to a different system and screen position.

The current `MusicalAnchor(systemIndex, normalizedFrame)` pins ink to *the n-th system*. That survives viewport zoom, staff-visibility toggles, and scroll, but **not** staff-size changes: after a reflow, "system 2" contains different measures, so the ink lands on the wrong measure. (The existing doc comment concedes this.)

Decision B anchors to **musical coordinates that do not change when the layout reflows** — measure, tick, and staff are stable; only their *screen positions* change, and we recompute those at render.

### 4.2 New `MusicalAnchor` (Domain model change — replaces the current one)

The x-coordinate mirrors the **playback cursor's tick model** so the same layout machinery (`cursorFrame` / `nearestCursor`, extended per §4.5) applies. It is **not** a `0…1` fraction of the measure width: the engine resolves measure-local x by non-linear interpolation between tick-keyed note/rest columns (`beatXInMeasure`), so a uniform fraction has no engine correspondence and no inverse.

```swift
/// A musical position an annotation is pinned to. Pure musical coordinates (Foundation-only); independent of any
/// computed layout, so it survives reflow / staff-size (content-zoom) changes / staff-visibility toggles. The Reader
/// (via SheetMusicLayout, §4.5) maps between this and on-screen layout points.
public struct MusicalAnchor: Hashable, Codable, Sendable {
    /// Zero-based index of the anchoring measure (stable across reflow). Mirrors ScoreCursor.beat.measureIndex.
    public let measureIndex: Int
    /// Tick offset within the measure (stable across reflow). Mirrors ScoreCursor.beat.tickInMeasure.
    public let tickInMeasure: Int
    /// Staff identity (stable across reflow), mirroring the engine's StaffAddress.
    public let partIndex: Int
    public let staffIndexInPart: Int
    /// Horizontal offset from the resolved tick column, in staff-spaces (sp). Preserves the relative x of strokes that
    /// snap to the same tick column (the inverse mapping is event/tick-quantized; dxSp restores sub-column precision).
    public let dxSp: Double
    /// Vertical offset from the top line of the staff, in staff-spaces (sp). Positive = downward.
    public let verticalOffsetSp: Double

    public init(measureIndex: Int, tickInMeasure: Int, partIndex: Int, staffIndexInPart: Int,
                dxSp: Double, verticalOffsetSp: Double) { /* … */ }
}
```

`UnitRect` is **removed** — its only consumer was `MusicalAnchor.normalizedFrame`; `UnitRectTests` is deleted with it.

### 4.3 Ink storage metric

`DrawingAnchor.encodedDrawing` stays `Data` (an opaque `PKDrawing`). The stored strokes are expressed in a **local frame whose origin is the anchor point and whose unit is one staff-space (sp)**. This makes reflow re-projection a pure *translate + uniform scale*:

- shapes do not distort (a circle stays a circle), and
- ink scales proportionally with the music when staff size changes.

**Simplification:** sp is **global per layout** (`StaffMetrics.sp = staffSize / 4`, uniform across all systems). So the reflow scale factor is a single scalar, `newDoc.metrics.sp / oldDoc.metrics.sp`; "sp at a position" is effectively one value per `LayoutDocument`.

### 4.4 Granularity: one `DrawingAnchor` per stroke

v1 stores **one `DrawingAnchor` per `PKStroke`**, each anchored by that stroke's leading point. Rationale: correct per-stroke reflow, trivial reconciliation (the model is "the set of current strokes, each tagged with an anchor"), and multi-stroke glyphs whose strokes share a tick stay together. A single stroke spanning several measures anchors to one measure and translates rigidly — the documented graceful-degradation edge.

### 4.5 Layout mapping — an upstream swift-sheet-music addition IS required

The Reader needs two mappings against the current layout. The existing primitives do **not** deliver them as-is:

- **Forward** `MusicalAnchor → (documentPoint, sp)`: the existing `cursorFrame(for:in:)` returns a **whole-system-height rect** (top = first staff origin, bottom = last staff bottom), i.e. only an x-column — not a per-staff point, not a vertical sp offset. The per-staff Y is computable (`system.origin.y + staffOrigins[staffIndex].y`, as `lyricLineY` already does) but not exposed as one call.
- **Inverse** `documentPoint → MusicalAnchor`: the existing `nearestCursor(at:in:)` **snaps to the nearest playable event** and returns only `.item` (never `.beat`, never a continuous sub-event position or a vertical sp offset); it can return `nil` in an empty region. The non-linear tick↔x logic (`beatXInMeasure`, `itemX`) is private.

So two **minimal, additive, pure** upstream primitives are required (consistent with D2 — layout math is upstream; these are also what a future Android annotation path would reuse, like `nearestCursor`/`cursorFrame` are reused today via `TapToCursor.kt`):

1. **Forward** — e.g. `func anchorPoint(measureIndex:Int, tickInMeasure:Int, partIndex:Int, staffIndexInPart:Int, in score:Score) -> (point: CGPoint, sp: CGFloat)?`, combining the measure-local x from `beatXInMeasure` with the per-staff origin `system.origin.y + staffOrigins[…].y`.
2. **Inverse** — extend `nearestCursor` (or a sibling) to return a **continuous** position: `measureIndex` + interpolated `tickInMeasure` + staff identity + horizontal `dxSp` from the tick column + vertical sp offset from the touched staff top, handling empty measures/staves instead of snapping-or-nil.

Both take the **full `Score`** (not just the `LayoutDocument`) for tick interpolation — the Reader already holds the Score at cursor/tap-seek time, but the reprojection path (§11) must keep both. In Paged mode the forward call must use the **page-local sub-document** the canvas is sized to (§5.2).

This upstream work follows the project ssm workflow (verify in the example app, report before push, re-pin folino). It is **not** a one-line accessor — a correct continuous inverse (handling empty measures, staff membership, ledger lines) is genuine engine design; budget it (Plan 2, §16).

## 5. Canvas hosting (decision A1)

### 5.1 The decision and why it does not double-implement scroll/zoom

The Reader's scroll/zoom is a custom stack: `ScoreScrollHost` (a `UIScrollView` with `min/maxZoomScale = 1`, used only for pan + gesture coordination) plus SwiftUI `.scaleEffect`s for zoom. The committed pinch math (`commitPinch` focal formula `currentOffset + startLocation*(ratio-1) - pinch.offset`, bounce-back, two-phase snap-to-unit) lives outside the render tree and runs once per gesture on scalars.

Two ways to add a canvas:

- **A1 (adopt):** insert the `PKCanvasView` (`isScrollEnabled = false`, sized to `doc.size`) **as a child of the already-transformed content** — a sibling of `ScoreView` inside each surface's `scoreSurface(...)` `ZStack(alignment: .topLeading)`, *beneath* both `.scaleEffect`s. It inherits the resolved scale + live-pinch pivot + pan + scroll **transform for free**, exactly as the existing AB-repeat overlays (`LoopRegionOverlay`, `LoopBoundaryMarkers`) already do. **One** copy of the zoom/position math (the existing one).
- **A2 (reject):** a screen-space sibling overlay *outside* the transform chain, which must re-derive zoom + offset + clamp every frame. **Two** copies — the double-implementation to avoid.

A two-phase adversarial code analysis (parallel deep-read of `ScoreScrollHost` + the three `*ZoomedSurface`/`*ScoreContainer` files + `ReaderViewModel`, then an affirm/refute pass) confirmed A1 reuses 100% of the pinch/scroll/zoom/position math with zero duplication. Verified facts:

- The transform is carried by ancestors of the insertion node (`.scaleEffect(pinch.magnification, anchor: pinch.anchor)` → `.scaleEffect(zoom, anchor: .topLeading)` → `.offset(...)` → `.frame(...)` on `scoreSurface(...)` output), plus `UIScrollView.contentOffset` which scrolls the whole `UIHostingController.view` bodily.
- The `"scoreSurface"` named coordinate space is registered on `ScoreView` *beneath* both scaleEffects, so it is **raw, un-zoomed document space**. A content-sized canvas in the same `ZStack` has bounds == document space; pencil points map 1:1 to document coords — the same free inverse tap-to-seek's `nearestCursor` already uses.
- `viewportZoom` is **transient** (`var` on `ReaderViewModel`, reset by `resetZoom()`), not persisted. Only `staffSize` is persisted; it re-runs layout and changes `doc.size`, and the canvas is sized to `doc.size`, so it is re-laid by the same engine output `ScoreView` consumes.

### 5.2 Insertion points

- **Vertical:** sibling of `ScoreView` in `VerticalZoomedSurface.scoreSurface(document:)`, peer of the loop overlays.
- **Horizontal:** sibling of `ScoreView` in `HorizontalZoomedSurface.scoreSurface(document:)`.
- **Paged:** `PagedZoomedSurface.pageContent(forPage:doc:)` assembles a **per-page sub-document** (`LayoutDocument.subdocument(systems:yOffset:)`), then renders it via `scoreSurface(document:pageStartY:pageHeight:)` which applies `.offset(y: -pageStartY)` + `.clipped()`. Insert **one canvas per page**, sized to the page sub-document; the forward mapping (§4.5) must be evaluated against that **page-local** document (else document-Y is off by `pageStartY`). Stroke persistence re-adds `pageStartY` to reconcile per-page canvases into the single document-space layer (bookkeeping, not pinch math).

### 5.3 Z-order, hit-testing, gesture coexistence

The canvas lives in the same `scoreSurface` `ZStack` as `ScoreView`, the playback-cursor overlay, the A-B loop overlays (`allowsHitTesting(false)`, passive), the `tapSeekGesture` (`SpatialTapGesture` on `"scoreSurface"`), and — in Paged — the band-swipe gesture. Unlike the loop overlays, the canvas **must accept input**. Layering/priority:

- **Annotation active (tool picker shown):** the canvas is the topmost interactive layer for its policy's input (pencil under `.pencilOnly`; one-finger under `.anyInput`). `tapSeekGesture` and band-swipe yield to drawing input; navigation input (finger when pencil present; two-finger otherwise) still reaches the host.
- **Annotation inactive:** the canvas does not intercept (drawing disabled / picker hidden); `tapSeekGesture`, cursor, loop overlays, and swipe behave exactly as today.

The `AnnotationInputRouter` (§6) owns this policy; exact gesture-priority wiring is validated by the §13.2 spike.

### 5.4 The one real risk (not the position math)

`PKCanvasView` is itself a `UIScrollView`; Apple's supported zoom path is canvas-owned (`canvas.zoomScale`), which keeps ink vector-crisp and maps touches into drawing space. This app deliberately disables that and applies an external `.scaleEffect` PencilKit cannot see. So two PencilKit-internal unknowns remain (spike, §13.1):

- **Ink fidelity:** does ink re-rasterize crisp under an ancestor `.scaleEffect(>1)`, or bitmap-upscale blurry?
- **Input mapping:** at committed zoom ≠ 1 and mid-live-pinch, does a stroke land at the correct document coordinate?

**Worst-case fallback is bounded to one scalar, not a second `commitPinch`:** mirror `canvas.zoomScale = effectiveZoom` (the value the surface already computes) in `updateUIView`, and exclude the canvas branch from the ancestor `.scaleEffect(zoom, ...)` to avoid double-scaling. The focal/clamp/snap math stays single-source regardless.

## 6. Input routing (pencil vs finger)

A small, first-class `AnnotationInputRouter` (Reader-internal) owns the policy:

- **Pencil paired:** `drawingPolicy = .pencilOnly`. Pencil → canvas draws; finger touches fall through to the existing host pinch + scroll (which already declare `shouldRecognizeSimultaneouslyWith == true`). No mode toggle.
- **No pencil:** `drawingPolicy = .anyInput`. One finger → canvas draws; two fingers → host pinch/scroll (Photos/Freeform), contingent on the §13.2 arbitration spike.

**Fallback (decision "C"), only if the no-pencil arbitration spike fails:** a "描き込み / Draw" toggle in the toolbar, shown **only when no Pencil is paired**. On → one finger draws; off → normal navigation. The Pencil path is unaffected. This degrades only the no-Pencil minority and is documented, not default.

Annotation is an *optional overlay* over a platform-neutral navigation layer — core reading never depends on PencilKit.

## 7. Persistence

- New `LiveAnnotationStore: AnnotationStore` in `Packages/Infrastructure/Sources/Persistence`, backed by the existing `AppDatabase` (GRDB `DatabasePool` + `DatabaseMigrator`).
- New migration (v12) adds an `annotation_layers` table: one row per score (`scoreItemID` unique), columns `id`, `scoreItemID`, `updatedAt`, and a serialized payload BLOB (the encoded `AnnotationLayer`; `PKDrawing` `Data` is binary). Greenfield — nothing persists annotations today, so the breaking anchor `Codable` change (§4) is safe with no data migration.
- **Soft-delete contract** (the repository has a two-stage lifecycle: `deleteScoreItem` → `softDeleteScoreItem` sets `deleted_at`; `restoreScoreItem` clears it; hard delete only in `permanentlyDeleteScoreItem` / `pruneScoreItemsDeleted` 30-day purge):
  - Trashing a score **preserves** its annotation layer, so **restore brings the ink back**.
  - The layer is dropped only on **hard delete / purge**. Implement as an `ON DELETE CASCADE` foreign key to `score_items(id)` (which fires only on the row `DELETE`, never on soft-delete), or by extending `permanentlyDeleteScoreItem` / `pruneScoreItemsDeleted`.
  - CloudKit treats a trashed-but-not-purged layer as **still present** (it disappears remotely only on purge).
- Wire `annotationStore` through the existing DI chain: `AppBootstrap.start()` (construct `LiveAnnotationStore(database:)`) → `AppShellView`'s private `ReadyShell.makeReader()` (the param is threaded through `ReadyShell.init` and its call site too) → `ReaderRootScreen` → `ReaderViewModel.init(...)`. Constructor injection only (no service locator), per the project DI rule.

## 8. Sync (CloudKit Private DB)

This is the first **concrete implementation** behind the existing `public protocol CloudSync` (whose doc comment already names `AnnotationLayer` among synced record types). Keep it minimal and annotation-scoped.

- CloudKit **Private** Database (`vision`/`privacy-and-accessibility.md`): the developer cannot read user data.
- One `CKRecord` per annotation layer, keyed by `scoreItemID`; the drawing payload travels as a `CKAsset` (binary blob) plus an `updatedAt` field.
- **Conflict resolution (v1): last-writer-wins on the whole layer by `updatedAt`.** Per-stroke merge is out of scope. (This makes the §9 save/debounce cadence relevant — a coarse `updatedAt` reduces false conflicts.)
- Local SQLite is the source of truth; CloudKit is additive (D4 — no iCloud Drive). A device overwrites its local copy when the remote `updatedAt` is newer.
- **v1 sync triggers: on layer save (push) + on app foreground (pull).** This needs **no** push entitlement. **Subscription-driven (silent push) pull is a follow-on**, because it additionally requires the `aps-environment` entitlement (absent), `remote-notification` in `UIBackgroundModes` (currently only `audio`), and `didReceiveRemoteNotification` plumbing — none of which exist.

**CloudKit bring-up (out-of-band, release-gating — not pure code):**

- The iCloud entitlement keys **already exist** — `App/Folino.entitlements` declares the container `iCloud.com.KeyNumber.Folino` and the `CloudKit` service. These are **not** part of this work.
- The CloudKit **container must still be provisioned** in the Apple Developer portal, and its **schema** (record type, the `scoreItemID` queryable index, the custom zone) **deployed Development → Production** before sync works in a release build. This is a known footgun; track it as a release step, not a code task.

The plumbing introduced here (zone, record mapping, save/pull) is structured so later record types (text boxes, playback prefs, playlists) can reuse it, but v1 wires only annotations.

## 9. Reader UI integration

- **Tool palette:** standard `PKToolPicker`, surfaced when the annotation layer is active. Pen/eraser/lasso/color/ruler and **undo/redo via the system `UndoManager`** come from PencilKit.
- **Per-stroke erase** is PencilKit's eraser; the model re-derives from `canvas.drawing.strokes` on `canvasViewDrawingDidChange`.
- **Save / debounce contract:** persistence is triggered on **pencil/finger lift, debounced (~0.5 s of inactivity)**; `AnnotationLayer.updatedAt` is bumped at each persisted save. This bounds CloudKit churn (last-writer-wins, §8) and reflow cost (§11). Not per-`canvasViewDrawingDidChange` (too chatty), not only on close (data-loss risk).
- **Activation:** with a Pencil, drawing is always live. Without a Pencil, drawing is live under `.anyInput` (or behind the §6 toggle fallback). An unobtrusive affordance shows/hides the tool picker.
- **Library indicator:** the library row shows a marker when a score has non-empty ink. v1 derives this from the `AnnotationStore`. **Risk:** a per-row async existence check is an N+1 against the single library list query; planning decides between a batched existence query and a denormalized `hasAnnotations` flag. If denormalized, the flag must update when a layer is emptied, deleted, trashed, restored, or pulled from a remote device.
- **Naming/localization:** user-facing strings use lowercase `folino` and natural language (no internal feature names like "Reader"); follow the `module.feature.thing` key scheme and the appropriate catalog.

## 10. Module / architecture placement

Respects the strict layering in `docs/engineering/module-architecture.md`:

- **Domain:** the changed `MusicalAnchor` (pure musical coords, Foundation-only) and existing annotation models/protocol — **promoted from `internal` to `public`** (only what crosses the module boundary, per the "minimize public" rule; `Sendable` on the ID types since `AnnotationStore` is `Sendable` and crosses an async boundary). No PencilKit, no layout dependency.
- **Infrastructure:** `LiveAnnotationStore` (Persistence) and the annotation CloudSync record mapping (CloudSync), behind the Domain `AnnotationStore` / `CloudSync` protocols.
- **Features/Reader:** the PencilKit **glue** only — the `PKCanvasView` representable, `AnnotationInputRouter`, the stroke↔anchor reconciliation orchestration, the tool picker. PencilKit/UIKit are Apple frameworks a Feature may import (the Reader already imports UIKit). The Reader reaches persistence only through the Domain `AnnotationStore` protocol (no Feature → Infrastructure).
- **swift-sheet-music (upstream):** the **pure** measure/tick/staff/sp ↔ document mapping primitives (§4.5) live in `SheetMusicLayout`, not in the Feature — engine-level and shareable, so a future Android annotation path reuses them (as it reuses `nearestCursor`/`cursorFrame`). The Reader only *calls* them.
- **App:** composition root wires `LiveAnnotationStore` into `ReaderViewModel`.

**iOS/Android parity:** the anchor model, the anchor↔document mapping, and the persistence/sync **envelope** (layer / anchor / `updatedAt`) are platform-neutral and shared. The PencilKit drawing surface + input router are iOS-only by necessity. **No divergent reimplementation of shared logic.** The `PKDrawing` ink blob is iOS-only payload on the shared envelope (§2 out-of-scope). PencilKit must stay strictly in the iOS-only Reader source set — never in any Android-gated Swift target — so the Android cross-compile is unaffected.

## 11. Reflow re-projection & stroke↔anchor reconciliation

- **Display (model → canvas):** for each `DrawingAnchor`, compute its document point + current sp from its `MusicalAnchor` against the current `LayoutDocument` **and** `Score` (the forward primitive needs both, §4.5); transform the stored sp-relative `PKStroke` to document coords (translate to the point, scale by current sp); assemble the canvas `PKDrawing`. The canvas (document space) then rides the ancestor transform (§5).
- **Capture (canvas → model):** on `canvasViewDrawingDidChange`, for each stroke not yet modeled, compute its anchor from its leading point via the inverse primitive; store the stroke in sp-relative coords (origin = anchor point, unit = current sp). Removed/modified strokes update/drop their anchors. Persist per the §9 debounce.
- **On reflow** (staff-size change → new `doc.size`): re-run *display* with the new layout; the scale factor is the single scalar `newSp / oldSp` (§4.3). Staff-size change is a discrete toolbar action (not a continuous gesture), so re-projection runs once per change — bounding cost. Per O3, if measured cost on baseline hardware (iPad 10th gen / iPhone 14) is too high with hundreds of strokes, defer the rebuild until the interaction settles.
- **Out-of-range / orphaned anchors:** if a `measureIndex` (or staff) no longer exists in the current `Score` (e.g. after a re-import with a different `content_hash`), the forward primitive returns `nil`; that anchor's stroke is **not rendered** and is **pruned on the next save**. (See §13 anchor-invalidation.)

## 12. Testing strategy

- **Domain:** pure unit tests for the new `MusicalAnchor` (Codable, field validation); **rewrite** `MusicalAnchorTests` (old shape) and update `AnnotationLayerTests` / `StorageProtocolsTests`; **delete** `UnitRectTests`.
- **Reader (with fakes):** unit-test the pure mapping/reconciliation functions — anchor → document point → anchor round-trips; sp-relative transform; reflow re-projection given two `LayoutDocument`s at different staff sizes (same measure → moved point, scaled by `newSp/oldSp`); stroke→anchor partitioning; out-of-range anchor pruning. The `AnnotationInputRouter` policy table (pencil/no-pencil → draw/scroll) tested in isolation.
- **Infrastructure:** `LiveAnnotationStore` SQLite round-trip (save/fetch/delete; soft-delete preserves, hard-delete/prune cascades) against a tmpdir DB. CloudSync record mapping tested against a fake CloudKit boundary (no real CloudKit).
- **swift-sheet-music (upstream):** unit tests for the new forward/inverse primitives in the ssm package, verified in the example app before push (ssm workflow).
- **Spikes (throwaway, not shipped):** §13.1 PencilKit-under-scale fidelity/input and §13.2 no-pencil arbitration are manual device/simulator harnesses, not unit tests.
- New tests use Swift Testing (`@Test`, `#expect`). Package tests run via `xcodebuild test` on the iPhone 17 Pro Max simulator (project rule — `swift test` is broken by the SwiftLint plugin).

## 13. Open questions / risks / spikes

1. **PencilKit under external `CALayer` scale (highest UI risk).** Spike: nest `PKCanvasView(isScrollEnabled: false, drawingPolicy: .pencilOnly)` under a SwiftUI `.scaleEffect(2.5)` (animate `magnification` to simulate live pinch) and verify (a) ink stays vector-crisp, (b) a stroke drawn at zoom 2.5 stores at the correct un-scaled document coordinate, (c) `.pencilOnly` lets the host pinch/scroll still claim two-finger/one-finger touches. Pass → ship A1 as-is. Fail → the bounded one-scalar `canvas.zoomScale` mirror (§5.4).
2. **No-pencil gesture arbitration.** Confirm one-finger-draw / two-finger-scroll with the canvas as a non-scrolling child over the host scroller, no mode toggle. Fail → the §6 "C" toggle fallback (no-pencil only).
3. **Upstream layout primitives (gating dependency).** The forward `anchorPoint` and the continuous inverse (§4.5) must be added to `SheetMusicLayout`. The continuous inverse (empty measures, staff membership, ledger lines) is non-trivial engine design — not a trivial accessor. Budget it as real ssm work; the whole Reader plan is gated on it.
4. **CloudKit first-integration risk.** Container provisioning + Dev→Prod schema deployment (out-of-band), account-status handling, first multi-device conflict test. New surface for the app; give it its own validation step (Plan 3).
5. **Anchor invalidation under structural edits.** `measureIndex` is durable across reflow/zoom but fragile across measure insert/delete (future Editor) and re-import (`content_hash` change). **v1 policy:** out-of-range anchors are not rendered and pruned on next save (§11). Revisit a more stable measure identity when the Editor gains measure mutation.
6. **O3 reflow performance** with hundreds of strokes on baseline hardware (§11) — measure; defer-on-settle if needed.
7. **Library indicator cost (§9)** — batched existence query vs denormalized flag.

## 14. Dependencies & upstream work

- **Required swift-sheet-music addition** for the §4.5 mapping primitives (forward `anchorPoint` returning per-staff document point + sp; continuous inverse position). Follow the ssm workflow (verify in the example app, report before push, re-pin folino). Not "small" — see §13.3.
- No new third-party dependency (PencilKit/CloudKit are system frameworks). No GPL.
- CloudKit container provisioning + schema deployment (out-of-band, §8).

## 15. Summary of decisions

| # | Decision | Choice |
|---|---|---|
| 1 | v1 layers | Free-hand drawing only (text boxes deferred) |
| 2 | Input | Pencil → draw + finger scroll; no-Pencil → 1-finger draw / 2-finger scroll (Photos/Freeform), no toggle (toggle = fallback) |
| 3 | Reflow accuracy | B — musical anchor (measure/tick + staff/sp), re-project at render; survives staff-size change |
| 4 | Canvas hosting | A1 — canvas as child of the transformed content; reuses all scroll/zoom math; one-scalar fallback for the PencilKit-under-scale edge |
| 5 | Sync | CloudKit Private DB, last-writer-wins per layer; v1 = save-push + foreground-pull |

## 16. Implementation decomposition (three plans)

The seams are clean and the risk profiles differ; the writing-plans step splits along them. **Plan 1 ships first and unblocks the others.**

- **Plan 1 — Domain + Persistence (zero UI, fully testable, low risk).** New tick-based `MusicalAnchor`; `internal → public` promotion + `Sendable` on ID types; `UnitRect` removal; rewrite `MusicalAnchorTests`/`AnnotationLayerTests`/`StorageProtocolsTests`, delete `UnitRectTests`; `LiveAnnotationStore` + SQLite v12 migration with the soft/hard-delete cascade. Greenfield persistence → the breaking `Codable` change is safe. Independent of every spike.
- **Plan 2 — Reader integration (highest uncertainty).** Canvas hosting (A1), `AnnotationInputRouter`, the upstream `SheetMusicLayout` primitives (§4.5) + folino re-pin, forward/inverse mapping, reflow re-projection, tool picker, save/debounce. Gated by the §13.1 and §13.2 spikes **and** the upstream ssm PR. Sequence with the §5.4/§6 fallbacks budgeted, not assumed away.
- **Plan 3 — CloudKit Private DB sync (first real CloudSync impl).** Zone / record mapping / `CKAsset` / last-writer-wins / save-push + foreground-pull, plus the out-of-band container provisioning + Dev→Prod schema deployment. Account-level dependencies and first-integration risk; its own validation. (Subscription-driven pull is a follow-on beyond v1.)

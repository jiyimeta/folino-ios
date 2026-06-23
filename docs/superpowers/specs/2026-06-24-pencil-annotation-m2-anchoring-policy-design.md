# Pencil Annotation M2 — Musical Anchoring Policy — Design

## 1. Goal & relationship to the parent spec

The parent spec [`2026-06-22-ipad-pencil-annotation-design.md`](2026-06-22-ipad-pencil-annotation-design.md)
(decision "B", §4) already fixed the annotation **data model**: ink is pinned to tick-based musical
coordinates (`MusicalAnchor`), re-projected to the current layout at render. That type is implemented
(`Packages/Domain/Sources/Domain/MusicalAnchor.swift`); M1 only ever fills it with an all-zero sentinel
and stores the whole canvas as one blob.

What the parent spec deliberately left thin is the **policy** that turns a drawn stroke into an anchor
and back — "by what criterion do we anchor." This doc decides that policy and **amends two points of the
parent spec** (§8). It is the input to the M2 implementation plan.

This doc changes **no product behavior, no module boundaries, no public Domain API** beyond what the
parent spec already committed (`MusicalAnchor` is unchanged). It refines a render/capture heuristic and
scopes the first milestone.

## 2. Decisions this doc locks (brainstormed)

| Axis | Decision | Source |
| --- | --- | --- |
| **Reference target** | tick-grid: `measureIndex` + `tickInMeasure` + staff identity + sp offsets | inherits parent §4.2 |
| **Span / granularity** | one anchor per stroke; reflow = rigid **translate + uniform scale** | inherits parent §4.4 |
| **Representative point** | **centroid (stroke bounding-box center)**, no event snapping; isolated behind one swappable function | **overrides** parent §4.4 ("leading point") |
| **Vertical / staff selection** | nearest staff by centerline; signed sp offset from that staff's top | **new precision** over parent §4.2/§4.5 |
| **First milestone (M2a)** | Vertical mode only | new scope decision |

Rationale recap: tick-grid is the only target that works in the whitespace where freehand ink frequently
lands (above the staff, between note columns), where no note/rest event exists to bind to. Rigid
single-anchor is exact for the dominant local marks (fingerings, bowings, small circles) and never
distorts ink; the only failure is a stroke wide enough to span a line break **combined with** a
staff-size change that moves a break between its endpoints — a narrow case that pinch-zoom (the common
zoom) never triggers because pinch does not reflow. The centroid beats the parent spec's leading point
on three counts: it is independent of draw direction, a circle's centroid lands on the note it encircles,
and under the rare rigid-span overhang the error splits to both sides of center instead of accumulating on
one end.

## 3. Anchoring policy in detail

### 3.1 Reference target — tick-grid (inherited)

Unchanged from parent §4.2. The stored value is `MusicalAnchor(measureIndex, tickInMeasure, partIndex,
staffIndexInPart, dxSp, verticalOffsetSp)`, all layout-agnostic. `dxSp` is the horizontal offset (in
staff-spaces) from the resolved tick column; `verticalOffsetSp` is the signed offset from the anchoring
staff's top line (positive = downward). The `MusicalAnchor` initializer clamps `measureIndex`,
`tickInMeasure`, `partIndex`, `staffIndexInPart` to `≥ 0` — anchors are always non-negative musical
coordinates; only `dxSp` / `verticalOffsetSp` may be negative.

### 3.2 Span / granularity — one anchor per stroke, rigid (inherited)

Unchanged from parent §4.4: **one `DrawingAnchor` per `PKStroke`**. Reflow re-projection is a pure
translate + uniform scale — shapes never distort (a circle stays a circle), and ink scales proportionally
with the music when staff size changes (scale factor = `newDoc.metrics.sp / oldDoc.metrics.sp`, a single
global scalar). A single stroke spanning several measures anchors to one point and translates rigidly; it
does not bend to follow measures that reflow onto different lines — the documented graceful-degradation
edge.

### 3.3 Representative point — centroid (OVERRIDES parent §4.4)

The point that becomes the anchor (and the fixed point of the reflow scale) is the **center of the
stroke's bounding box** in document space, **not** the stroke's leading point.

- Computed from the `PKStroke`'s rendered path bounds (`renderBounds` / sampled path), so it is
  independent of which end the user started from.
- **No event snapping in v1.** The centroid maps to the *continuous* tick at that document point (via the
  inverse primitive, §6); it is not pulled onto the nearest notehead's column. This keeps marks in
  whitespace and over rests faithful and avoids a snapping pass.
- **Swappable seam.** The representative-point choice lives behind a single function (e.g.
  `AnnotationAnchorPolicy.representativePoint(of: PKStroke) -> CGPoint`) so it can later become
  leading-point or nearest-note snapping **without changing the stored format** — the anchor is always a
  `MusicalAnchor`, so existing ink stays compatible regardless of the heuristic. (The user explicitly
  wants to ship the centroid and test the feel before committing further.)

### 3.4 Vertical / staff selection (new precision)

Given the representative point `c` in document space:

1. **Which staff** — choose the staff whose **centerline is nearest** to `c.y` across all rendered staves
   in the system containing (or nearest to) `c.y`. This yields the `(partIndex, staffIndexInPart)`
   identity. Binding to a concrete staff identity (not "system top") keeps the anchor robust when staff
   *visibility* toggles change a system's composition.
2. **Vertical offset** — `verticalOffsetSp = (c.y − staffTopY) / sp`, signed. A mark above the top staff
   is negative; a mark below the bottom staff or in a grand-staff gap is `> staffHeight/… sp` of the
   nearest staff. One rule covers staff-internal marks, above-system markings, and inter-staff marks.

Because staff *spacing* also scales with `sp`, a mark in the gap between two staves keeps its
proportional placement under staff-size change automatically (it is stored in sp relative to one staff's
top).

## 4. Algorithms

**Resolved anchor point `P`.** The forward primitive (§6) returns only the *reference* point (the tick
column's x at the staff's top y) plus the current `sp`. The full anchor point composes the stored offsets
onto it:

```
let (ref, sp) = forward(measureIndex, tickInMeasure, partIndex, staffIndexInPart, in: score)
let P = CGPoint(x: ref.x + dxSp * sp, y: ref.y + verticalOffsetSp * sp)
```

`P` is the single reference used by both capture (as the stored stroke's origin) and display (as the
translate target), so the round-trip is exact at the capture layout.

### 4.1 Capture — stroke → anchor (canvas → model), OVERRIDES parent §11 "leading point"

On `canvasViewDrawingDidChange`, for each stroke not yet modeled:

1. `c = representativePoint(of: stroke)` (centroid, §3.3) in document space.
2. Inverse primitive (§6): `c → (measureIndex, continuous tickInMeasure, partIndex, staffIndexInPart,
   dxSp, verticalOffsetSp)`. Staff identity per §3.4. The inverse is built so the recomposed `P` (above)
   equals `c` at the capture layout.
3. Store the stroke in **sp-relative coordinates**: origin = `P`, unit = the capture layout's `sp` (so
   `storedPoint = (strokePoint − P) / sp`). Because `P == c` here, capture→display round-trips with zero
   net offset at the capture layout.
4. Build `DrawingAnchor(anchor:, encodedDrawing:)`; removed/modified strokes update or drop their anchors.
   Persist per the parent §9 debounce.

### 4.2 Display — anchor → screen (model → canvas)

For each `DrawingAnchor`, against the current `LayoutDocument` + `Score`:

1. Compute `P` and `sp` for the current layout (forward primitive + offset composition, above). If the
   forward primitive returns `nil`, skip the stroke (§5).
2. Transform the stored sp-relative `PKStroke` back to document coords: `docPoint = storedPoint * sp + P`
   (scale by current `sp`, translate to `P`).
3. Assemble the canvas `PKDrawing`. The canvas (document space) then rides the ancestor scroll/zoom
   transform (parent §5) — no per-stroke pinch math.

### 4.3 On reflow (staff-size change)

Re-run *display* with the new layout. Scale factor is the single scalar `newSp / oldSp`. Staff-size
change is a discrete toolbar action (not a continuous gesture), so re-projection runs once per change.
Per parent O3, if measured cost with hundreds of strokes on baseline hardware (iPad 10th gen) is too high,
defer the rebuild until the interaction settles.

## 5. Invalidation & staff-visibility policy

- An anchor whose forward resolution returns `nil` — its `measureIndex` or `(partIndex,
  staffIndexInPart)` no longer exists in the current layout — is **not rendered** and is **pruned on the
  next save**. Carries parent §11 / open-question 5.
- **Staff visibility toggle** uses the same path: a hidden staff makes the forward primitive return `nil`
  for anchors on it, so their ink disappears; re-showing the staff brings the ink back (forward resolves
  again). No special-casing — visibility is just a layout that omits a staff.
- **Soft-delete / restore** is unchanged from the parent spec (the layer survives trashing; ink returns on
  restore).

## 6. Upstream swift-sheet-music primitives (gating dependency, inherited from parent §4.5)

Two minimal, additive, pure primitives in `SheetMusicLayout` (engine-level, also reusable by a future
Android annotation path):

1. **Forward** — `func anchorPoint(measureIndex:Int, tickInMeasure:Int, partIndex:Int,
   staffIndexInPart:Int, in score:Score) -> (point: CGPoint, sp: CGFloat)?` — measure-local x from
   `beatXInMeasure`, per-staff origin `system.origin.y + staffOrigins[…].y`. Returns `nil` when the
   measure/staff is absent from the current layout (drives §5).
2. **Inverse** — a continuous sibling of `nearestCursor`: `documentPoint → (measureIndex, interpolated
   tickInMeasure, partIndex, staffIndexInPart, dxSp from the tick column, verticalOffsetSp from the
   touched staff top)`, handling empty measures / empty staves instead of snapping-or-nil.

These are **not** trivial accessors — the continuous inverse (empty measures, staff membership, points
above/below the staff) is real engine design (parent §13.3). The whole M2 Reader integration is gated on
this ssm work, which follows the ssm workflow (verify in the example app → report before push → re-pin
folino).

## 7. Scope — M2a = Vertical only

The anchor is mode-independent (musical), but canvas hosting and re-projection differ per mode:

- **Vertical** — canvas already hosted (M1). M2a adds anchor population (§4.1) + display re-projection
  (§4.2) + reflow (§4.3) here. This is where the centroid heuristic and the overall feel get validated.
- **Horizontal** (`annotationOverlay: nil` today) and **Paged** (per-page canvas, page-local document +
  `pageStartY` reconciliation, parent §5.2) are **deferred to M2b**, after the Vertical feel is confirmed.
  The re-projection logic is shared; the deferred work is mostly hosting plumbing, so deferring it costs
  little and de-risks the policy first.

The implementation plan should still author the policy mode-agnostically (so M2b is hosting only), but the
shippable M2a milestone targets Vertical.

## 8. Amendments to the parent spec

This doc supersedes the following in `2026-06-22-ipad-pencil-annotation-design.md`:

- **§4.4** — "each anchored by that stroke's **leading point**" → **centroid (bbox center)**, isolated
  behind a swappable policy function (§3.3 here). The one-anchor-per-stroke and rigid-reflow decisions are
  unchanged.
- **§11 Capture** — "compute its anchor from its **leading point**" → from the **centroid** (§4.1 here).
- **Adds** the explicit vertical/staff-selection rule (§3.4) and the M2a Vertical-only scoping (§7), which
  the parent spec left unspecified.

Everything else in parent §4–§16 (the `MusicalAnchor` shape, sp storage metric, canvas hosting A1, input
routing, persistence, sync, module placement, the §4.5 primitives) carries unchanged.

## 9. Testing strategy

- **Policy unit tests (Domain-adjacent / Reader, with a fake layout):** centroid computation is
  direction-independent (same anchor for a stroke and its reverse); capture→display round-trip at the same
  layout is identity (zero net offset); staff-size change scales ink by exactly `newSp/oldSp`; an anchor on
  an absent measure/staff yields no rendered stroke.
- **Vertical / staff selection:** a mark between two staves picks the nearer centerline; a mark above the
  system anchors to the top staff with negative `verticalOffsetSp`.
- **Invalidation:** hide-then-show a staff round-trips the ink; an out-of-range anchor is pruned on save.
- **ssm primitives:** unit-tested upstream in `SheetMusicLayout` (forward/inverse round-trip on sample
  scores, including empty measures and points above/below the staff), per the ssm workflow.
- Existing parity: feature tests run against hand-written fakes (no real layout engine where avoidable),
  consistent with the repo's testing rules.

## 10. Open questions / risks (carried)

- **Gating ssm primitives (parent §13.3)** — the continuous inverse is the main uncertainty; budget it as
  real engine work. M2a cannot land before it.
- **Reflow performance (parent O3)** — measure with hundreds of strokes; defer-on-settle if needed.
- **Anchor durability under structural edits (parent open-question 5)** — `measureIndex` is durable across
  reflow/zoom but fragile across future measure insert/delete (Editor) and re-import; v1 policy is
  not-render + prune (§5).
- **Centroid feel** — the user wants to ship centroid and judge the feel before deciding whether to add
  leading-point or note-snapping; the swappable seam (§3.3) keeps that change cheap and format-compatible.

## 11. Summary of decisions

1. Anchor target = tick-grid `MusicalAnchor` (inherited; type already implemented).
2. One anchor per stroke; reflow = rigid translate + uniform scale (inherited).
3. Representative point = **centroid**, no snapping, behind a swappable policy seam (**overrides** parent
   leading-point).
4. Vertical = nearest-staff-by-centerline + signed sp offset from staff top (new precision).
5. Invalidation/visibility = forward-nil ⇒ not rendered, pruned on save (inherited, made explicit for
   staff-visibility).
6. Upstream ssm forward/inverse primitives required and gating (inherited).
7. First milestone M2a = Vertical only; Horizontal/Paged deferred to M2b (new scope).

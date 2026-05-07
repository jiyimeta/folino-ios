# Reader A–B Repeat — Boundary Markers Design

Date: 2026-05-07
Status: Approved (brainstorming complete, awaiting user spec review)

## Goal

Make the A and B endpoints of an active A–B section loop visible **on the
score itself** as discrete marks, not just as the translucent measure band
already drawn by `LoopRegionOverlay`. Practical motivation: when the band
covers several measures across multiple systems, the user can't tell at a
glance exactly which barline is A vs B. Adding a small triangle-topped
vertical line at each endpoint resolves that.

## Non-goals

- Changing snap semantics. A still snaps to the head of its measure, B to
  the end. Sub-measure A/B placement is out of scope.
- Replacing the existing translucent measure band. The band stays — markers
  are drawn on top of it as endpoint indicators.
- Editing the loop by dragging the markers. Markers are display-only in v1;
  the A/B pill remains the only way to set or clear endpoints.
- Any visual change for `repeatMode == .loopAll` (whole-score loop). Markers
  are only meaningful for user-set A/B.

## User-visible behavior

Markers appear **only when** `repeatMode == .abLoop` and both `abRepeat`
endpoints are set. (Same gating as the existing band — driven from the
same `viewModel.abRepeat` / `viewModel.repeatMode` pair.)

### A marker

- A vertical line drawn **immediately after** the barline that opens
  `range.start.measureIndex` — i.e. at the left edge of that measure
  (`system.origin.x + measure.origin.x`).
- A small filled triangle pointing **right (▶)** sits on top of the line,
  just above the system, with the triangle's base flush against the line's
  top end.
- The line itself extends from the **system top** down to the **system
  bottom** (matching the existing band's Y span), then is extended **upward
  by the triangle's height** so the triangle sits entirely above the staves
  rather than overlapping the topmost staff.

### B marker

- Mirror of A: vertical line **immediately before** the barline that closes
  `range.end.measureIndex` — i.e. at the right edge of that measure
  (`system.origin.x + measure.origin.x + measure.width`).
- Triangle points **left (◀)**.
- Same line extension above the system as A.

### Multi-system loops

When A and B are on different systems, only A's marker is drawn on A's
system and only B's marker on B's system. The band continues to span
intermediate measures on intermediate systems. Systems with no A and no B
get no marker (just the band).

### Same-system A/B

When A and B are in the same system (or even the same measure), both
markers are drawn at their respective edges. A 1-bar loop with A at the
measure's left edge and B at the measure's right edge produces two facing
triangles (▶ … ◀) capping the band.

## Visual specification

| Property | Value |
| --- | --- |
| Line color | `.accentColor` (matches cursor and the existing band fill) |
| Line opacity | 1.0 (full saturation; the band is the translucent layer, the markers are the crisp endpoints) |
| Line thickness | Slightly thinner than the playback cursor: target `metrics.sp * 0.5` (cursor uses `sp * 0.8`). Tunable at implementation time if it reads as too thin in preview. |
| Line Y span | `systemTop − triangleHeight` to `systemBottom` (where `systemTop = system.origin.y`, `systemBottom = system.origin.y + system.size.height` — same Y bounds the band uses) |
| Triangle | Filled `accentColor` isoceles triangle. Width ≈ `metrics.sp * 1.2`, height ≈ `metrics.sp * 1.0`. A points right (apex on +X side), B points left (apex on −X side). The triangle's flat side aligns with the line: A's flat side is on the **left** of the line, B's flat side is on the **right** of the line. Apex extends outward (away from the loop interior). |
| Z-order | Drawn **above** `LoopRegionOverlay`'s band so the crisp endpoint reads against the soft fill. Drawn **below** the playback cursor so an active cursor still occludes a marker if they overlap. |

The exact `sp` multipliers above are starting points. Final values are
locked in during implementation by rendering preview snapshots and tweaking
until the markers visually balance against the cursor and band on a real
score.

## Architecture

### New view: `LoopBoundaryMarkers`

A new SwiftUI view in the Reader package, sibling to `LoopRegionOverlay`
inside `Packages/Features/Reader/Sources/Reader/`. Same shape as the
existing overlay:

```swift
struct LoopBoundaryMarkers: View {
    let document: LayoutDocument
    let range: ABRepeatRange?
    var body: some View { /* Canvas-based draw */ }
}
```

It uses the same `LayoutDocument` already passed into
`LoopRegionOverlay`, so no new geometry plumbing is required. Implementation
uses `Canvas` with two phases:

1. Walk `document.systems` to find the measure for `range.start.measureIndex`
   (A-side) and `range.end.measureIndex` (B-side). For each, compute the
   line rect and triangle path.
2. Stroke / fill them into the canvas with `.color(.accentColor)`.

If either endpoint's measure is not found in `document.systems` (mid-render
layout swap, stale range), that side simply isn't drawn. The component is
defensive in the same way `LoopRegionOverlay` is.

### Wiring

`scoreSurface(document:)` in both `VerticalScoreContainer.swift` and
`HorizontalScoreContainer.swift` already gates the `LoopRegionOverlay` on
`viewModel.repeatMode == .abLoop`. Add a sibling line in the same
conditional block:

```swift
if viewModel.repeatMode == .abLoop {
    LoopRegionOverlay(document: doc, range: viewModel.abRepeat)
    LoopBoundaryMarkers(document: doc, range: viewModel.abRepeat)
}
```

ZStack order makes the markers appear above the band, as specified.

### Pure helpers (testable)

Extract two small functions for unit testing without SwiftUI:

```swift
func aMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat
) -> (line: CGRect, triangle: Path)?

func bMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat
) -> (line: CGRect, triangle: Path)?
```

These take a `LayoutDocument` plus geometry constants and return the
rect/path pair. The view calls them inside its `Canvas`. Tests construct a
small fake `LayoutDocument` and assert on the resulting rects.

## Testing

- **Unit (Reader)**:
  - `aMarkerGeometry` returns line rect with X = measure left edge and Y
    spanning `systemTop − triangleHeight` to `systemBottom`.
  - `bMarkerGeometry` returns line rect with X = measure right edge.
  - Both return `nil` when the requested measure index isn't present in
    any system.
  - Triangle path orientation: A's path apex has greater X than its base
    edge; B's apex has lesser X than its base edge.
- **Snapshot / preview**:
  - Add (or extend) a `#Preview` in `VerticalScoreContainerPreviews.swift`
    that pre-seeds `viewModel.repeatMode = .abLoop` and `abRepeat` covering
    a multi-bar span. Render via `mcp__xcode__RenderPreview` per the
    project's iOS workflow and visually confirm the markers cap the band
    correctly. Iterate `sp` multipliers there.
  - Add a same-measure A=B=measure-N preview to confirm both triangles
    fit when the line spacing collapses.

## Open implementation questions (for the plan, not this spec)

1. Final `sp` multipliers for line thickness and triangle dimensions.
   Decided in preview during implementation.
2. Whether the markers should also subtly animate in / out when entering
   `.abLoop` mode (matching whatever entrance the band uses today). v1
   matches the band's behavior exactly — no separate animation curve.
3. Whether to also draw markers when only one endpoint is set (e.g. just
   A) as an "in-progress loop" indicator. v1 keeps the existing
   "both-or-neither" gating; revisit if user feedback wants live A
   feedback before B is set.

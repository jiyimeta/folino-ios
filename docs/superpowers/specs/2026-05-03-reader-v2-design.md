# Reader v2 Design — Reader UX

**Status:** Draft for review
**Date:** 2026-05-03
**Successor of:** Plan #4 (Library + Minimum Reader). Plan #5 in the implementation roadmap.

## Goal

Bring the Reader screen up to its v1 spec for the *display* pillar only:
vertical / page mode toggle, page-turn taps and edge swipes, pinch
viewport zoom, content (staff-size) zoom, per-staff visibility, and
chrome auto-hide. Playback, annotations, editing, and the playback
cursor are explicitly out of scope and land in their own plans.

After this plan, opening a score in Folino feels like a real reader: a
performer can pick a layout mode, dial the engraved size, hide
unneeded staves, zoom in to inspect a passage, and turn pages with one
tap. They cannot yet hear it, mark it up, or edit it.

## Non-Goals

- **Playback** (transport, mixer, A–B, metronome, tempo) — Plan B.
- **Cursor** (display + tap-to-set) — Plan B. The hit-tester wiring,
  long-press recognizer, and `PlaybackController` interaction land
  together where they make sense as one UX.
- **Annotations** (PencilKit + text boxes, anchor-based persistence) —
  separate plan.
- **Editing** (System Text / Staff Text) — separate plan.
- **PDF mode** — post-v1 per roadmap.

## Architectural Position

```
App  ──▶ Library ──▶ Domain ◀── Infrastructure
 │   ╲   Reader  ──▶ Domain  (NEW: ReaderPreferences model + repo methods)
 │    ╲  Settings──▶ Domain
 │     ╲
 │      ╲▶ LicenseList (App-only)
 │
 └─ existing wiring; no new adapter graphs.
```

Reader continues to consume `SheetMusicUI` directly (`ScoreView`,
`PagedScoreView`) per `docs/engineering/module-architecture.md`. No
new Infrastructure adapter is added except the SQLite columns / table
that back `ReaderPreferences` persistence — wired into the existing
`LiveScoreLibraryRepository`.

## Persistence Model

User-facing settings split by scope:

| Setting | Scope | Storage |
|---|---|---|
| Layout mode (vertical / page) | Global | `@AppStorage("reader.layoutMode")` (string raw value) |
| Content staff size | Per-score | `ReaderPreferences.staffSize` |
| Hidden staff indices | Per-score | `ReaderPreferences.hiddenStaffIDs` |
| Pinch viewport zoom + pan | Session only | `@State`; resets on dismiss |
| Chrome visibility | Session only | `@State`; defaults to `true` on appear |
| Page index (page mode) | Session only | `@State` |

### New Domain type

```swift
public struct ReaderPreferences: Hashable, Sendable, Codable, Identifiable {
    public let id: ReaderPreferencesID         // new ID type, mirrors PlaybackPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: CGFloat              // clamped 8…28 in init
    public var hiddenStaffIDs: Set<Int>        // empty = show all
}
```

### `ScoreLibraryRepository` additions

```swift
func loadReaderPreferences(for scoreItemID: ScoreItemID) async throws -> ReaderPreferences?
func saveReaderPreferences(_ preferences: ReaderPreferences) async throws
```

`load…` returns `nil` when the user has never opened this score; the
view model fills in defaults (see §Defaults) and saves on first
mutation.

### Infrastructure: SQLite

A new `reader_preferences` table keyed by `score_item_id` with
columns `id TEXT NOT NULL`, `staff_size REAL NOT NULL`, and
`hidden_staff_ids TEXT NOT NULL` (JSON-encoded `[Int]`). The `id`
column mirrors the `ReaderPreferencesID` carried by the Domain type
so future CloudKit sync (post-v1) has a stable record key, parallel
to how `playback_preferences` is shaped. Use the existing migration
scaffold added in Plan #3. The
table is owned by the same database file; no schema-cascading concerns
because no other table references it. CloudKit sync of these
preferences is a follow-up — they remain device-local in v1, matching
the spirit of "nice-to-have polish" UX state.

## Defaults

| Knob | Default |
|---|---|
| Layout mode | `.vertical` |
| Staff size on iPad regular | 14 pt |
| Staff size on iPhone compact | 11 pt |
| Hidden staves | none |

The first time a score is opened, the view model picks the device-class
default for `staffSize` and saves a `ReaderPreferences` record. After
that, it is per-score regardless of which device opens it next.

The staff-size range 8…28 pt is enforced in the `ReaderPreferences`
initializer (clamped) so the persistence layer cannot store values
that break layout. UI exposes the same range with 1 pt steps.

## Gesture Scheme

Per the gesture-scheme decision (locked 2026-05-03):

| Gesture | Page mode | Vertical mode |
|---|---|---|
| Tap left 25% | Previous page | — |
| Tap right 25% | Next page | — |
| Tap center 50% | Toggle chrome | Toggle chrome |
| Edge → center swipe (left/right) | Previous / next page | — |
| Pinch | Viewport zoom | Viewport zoom |
| One-finger drag (only when zoom > 1.0) | Pan | Pan (horizontal scroll) |
| Double-tap | Toggle 1.0 ⇄ last zoom | Toggle 1.0 ⇄ last zoom |
| Long-press anywhere | *(reserved for cursor in Plan B)* | *(reserved for cursor in Plan B)* |

While zoom > 1.0 in page mode, page-turn tap zones and edge swipes
are suspended; pinch out to ≤ 1.0 snaps back to fit and re-enables
them.

iPhone and iPad use the identical scheme. Tap-zone widths are
expressed as fractions of container width so they hold across devices
and orientations.

External keyboard support (←/→/Space) is out of scope here; tracked
as a v1 follow-up.

## View Composition

```
ReaderView
├─ ReaderToolbar (chrome)            // .opacity(isChromeVisible ? 1 : 0)
├─ ZStack
│   ├─ ReaderGestureLayer
│   │   └─ scaled/panned content     // .scaleEffect(viewportZoom).offset(viewportPan)
│   │       └─ switch layoutMode {
│   │            .vertical → VerticalScoreContainer(document, score)
│   │            .page     → PagedScoreView(score: score, options:,
│   │                          pageIndex: $pageIndex,
│   │                          totalPages: $totalPages)
│   │          }
│   └─ PageTurnZoneOverlay (page mode, hit-shape only — invisible)
└─ .inspector(isPresented: $isInspectorPresented) {
       StaffVisibilityInspector(score: …, hidden: $hiddenStaffIDs)
   }
```

### `VerticalScoreContainer`

Owns a pre-computed `LayoutDocument` so layout runs once per
`(score, staffSize, availableWidth)` change, not on every body pass.
Mirrors the `verticalDoc` pattern from `swift-sheet-music`'s example
(`Example/SheetMusicExample/ContentView.swift`). Re-using a stable
document also lets Plan B drop in `ScoreHitTester` without rebuilding
layout.

### `ReaderGestureLayer`

Wraps content in:

- `MagnifyGesture` (iOS 17+ name; we are on iOS 26) — drives
  `viewportZoom` (state). Snap to 1.0 when ending below 1.05.
- `DragGesture(minimumDistance: 1)` — drives `viewportPan` only when
  `viewportZoom > 1.0`.
- `SpatialTapGesture` — exposes location; converts to fractional X
  using GeometryReader; routes to `prev / chrome / next` for page
  mode or `chrome` for vertical mode.
- `DragGesture` (separate, threshold-gated) for edge swipes in page
  mode, only when `viewportZoom == 1.0`.

This layer is a pure View + a small struct of gesture-state for
testability. Tap-zone routing logic lives in a free function:

```swift
enum PageModeTapZone { case prev, chrome, next }
func tapZone(forX x: CGFloat, width: CGFloat) -> PageModeTapZone
```

…tested directly without SwiftUI.

### `StaffVisibilityInspector`

Built on `.inspector(isPresented:content:)` (iOS 17+, available on our
iOS 26 target). On compact horizontal size class, `.inspector`
auto-presents as a sheet — no manual fallback needed. Contents:

- One row per `Score.staves[*]` with name (resolved via the parent
  `Part.trackName` / `Part.instrument`, falling back to "Staff N") and
  a `Toggle`.
- Footer buttons: "Show All" / "Hide All".
- Future Mixer section will be appended below this when Plan B lands;
  the visibility section is extracted as `StaffVisibilitySection` so
  Plan B can compose without surgery.

## Hidden-Staff Filtering

`SheetMusicUI` does not expose a "render with these staff IDs hidden"
parameter today. We work around this by handing `ScoreView` a copy of
`Score` with the hidden staves removed:

```swift
extension Score {
    func filtered(hidingStaffIDs ids: Set<Int>) -> Score
}
```

This helper lives in the Reader package (it is renderer-agnostic
massaging of an existing public model). Implementation:

1. Drop entries from `staves` whose `StaffContent.id` is in `ids`.
2. Drop the matching `StaffDeclaration` entries from each `Part` so
   labels and bracket grouping stay consistent.
3. Drop a whole `Part` if all its staves were hidden — otherwise
   instrument labels and brackets render against an empty group.

### Risk: layout invariants

`Score.staves[*].id` is what `SheetMusicLayout` uses to wire chord
positions, beams, and selection back to the model. If layout assumes
contiguous IDs starting at 0, naively dropping rows in the middle
will mis-align rendering. The plan must include an early spike that
opens a 4-staff score, hides staff index 1, and validates that the
remaining staves render correctly. Two outcomes:

- **Spike passes:** ship `Score.filtered(hidingStaffIDs:)` as
  designed.
- **Spike fails:** retreat to a "hide all but the first/last N"
  cut-down, file an issue against `swift-sheet-music` for a
  `staffMask` parameter on `ScoreView`, and ship the visibility UI
  with reduced functionality marked TODO until upstream lands.

The spike is small enough (one #Preview + a paste-in 4-staff fixture)
that it goes at the top of the implementation plan and gates the rest
of the staff-visibility work.

## ReaderViewModel

```swift
@MainActor @Observable
public final class ReaderViewModel {
    public enum LoadState { case loading, loaded(Score), failed(message: String) }

    public private(set) var loadState: LoadState = .loading
    public private(set) var scoreItem: ScoreItem
    public private(set) var preferences: ReaderPreferences   // populated post-load
    public var pageIndex: Int = 0
    public var totalPages: Int = 1
    public var isChromeVisible: Bool = true
    public var isInspectorPresented: Bool = false
    public var viewportZoom: CGFloat = 1.0
    public var viewportPan: CGSize = .zero
    public var lastNonUnitZoom: CGFloat = 1.0   // double-tap toggle target

    // Globally-scoped layout mode is read/written via @AppStorage
    // from the View; the VM exposes the current value as a parameter
    // to its render-relevant methods rather than holding it.

    public func incrementStaffSize() async  // +1 pt, clamps to 28, persists
    public func decrementStaffSize() async  // –1 pt, clamps to 8, persists
    public func toggleStaff(id: Int) async  // updates hiddenStaffIDs, persists
    public func showAllStaves() async
    public func hideAllStaves() async
    public func resetZoom()                 // viewportZoom = 1.0, pan = .zero
    public func toggleZoom(targetIfZoomedOut: CGFloat = 2.0)
}
```

Persisted mutators all `try? await repository.saveReaderPreferences(…)`;
errors are silently absorbed because the user-facing setting has
already taken effect locally and a missed save is recoverable next
time.

## Chrome / Toolbar

| Slot | Contents |
|---|---|
| leading | Existing nav (sidebar toggle on iPad regular, Back on iPhone compact) |
| principal | Score title (existing) |
| trailing | Mode segmented control (vertical / page), Zoom −, Zoom +, Inspector toggle |
| bottom (page mode only) | "page X of Y" indicator |
| floating, page mode + zoom > 1.0 | "Reset zoom" pill button |

The toolbar is hidden by `isChromeVisible == false`. While hidden, a
single tap in the center 50% restores it. The status bar follows
chrome visibility (use `.statusBar(hidden: !isChromeVisible)` on
iPhone for full-immersion reading).

## Testing Plan

### Unit (Swift Testing)

- `ReaderPreferencesTests`: clamping (staff size, empty hidden set),
  Codable round-trip.
- `ReaderViewModelTests`:
  - first open populates defaults from device class
  - increment/decrement/toggle persist via the fake repository
  - `showAllStaves` / `hideAllStaves` write the expected sets
  - `resetZoom` and `toggleZoom` mutate state correctly
- `TapZoneRoutingTests`: pure function tests at boundary widths
  (0, 0.249w, 0.25w, 0.5w, 0.75w, 0.751w, w).
- `ScoreFilteringTests` (Reader package, fixture-driven): dropping
  staves preserves remaining staff order, drops all-empty parts,
  preserves a `Part` with at least one visible staff.

### Infrastructure

- `LiveScoreLibraryRepositoryTests`: load returns `nil` when no row,
  save then load round-trips, save updates an existing row in place.

### Preview-driven verification

Per the iOS workflow, every visual surface gets a `#Preview`:

- `ReaderView` in vertical mode at the iPad regular default
- `ReaderView` in page mode at the iPhone default
- `ReaderGestureLayer` overlay debug (page-turn zone shading visible)
- `StaffVisibilityInspector` populated from a 4-staff fixture

Iterate via `mcp__xcode__RenderPreview`.

### Manual / simulator

- Page-mode page-turn taps and edge swipes (gesture timing not
  reliably reproduced by previews).
- Pinch + pan + double-tap toggle.
- Hide-staff round-trip: hide → close score → reopen → still hidden.
- Mode toggle persists across app launches (global), staff size
  persists per-score (open A, change size, open B, change size, open
  A again — A's size returns).

## Implementation Order Hint

(Detailed plan lands in a separate `docs/superpowers/plans/...` file.)

1. Spike: `Score.filtered(hidingStaffIDs:)` validation against a
   real 4-staff score.
2. Domain: `ReaderPreferences` + ID type + repo protocol additions.
3. Infrastructure: SQLite table + Live repo methods + tests.
4. Reader package: `ReaderViewModel` extensions + `tapZone`
   routing function + `Score.filtered` helper.
5. Reader package: `ReaderGestureLayer`, `VerticalScoreContainer`,
   `StaffVisibilityInspector`, `ReaderToolbar`.
6. Reader package: assemble `ReaderView`, wire previews.
7. App: pass `ReaderPreferences` repo methods through the existing
   `repository` already given to `ReaderView`. No `AppShellView`
   surgery beyond making sure `@AppStorage` reads of the layout-mode
   key work in both compact and regular shells.
8. Localization strings (en + ja `.xcstrings`).
9. Manual verification in simulator on both iPhone 16 and iPad Air.

## Open Items / Risks

- **`Score.filtered` correctness** (see §Hidden-Staff Filtering risk).
- **`PagedScoreView` cursor parameter**: currently the public init
  doesn't accept a `playbackCursor`. Plan B will need either an
  upstream change or a workaround. Out of scope for this plan but
  noted so we don't design ourselves into a corner — the
  page-mode renderer here doesn't take a cursor argument (none to
  show), and we won't add a wrapper that pretends to.
- **CloudKit sync of `ReaderPreferences`**: device-local in v1.
  Mentioned here so a future plan can address it without surprise.
- **External-keyboard page turning**: deferred follow-up.

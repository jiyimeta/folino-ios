# Reader page mode

## Goal

Add a third Reader layout mode — `.page` — alongside the existing
`.vertical` and `.horizontal` modes. Page mode paginates the score by
viewport height and exposes one page at a time, mirroring the
`.paged` case of `swift-sheet-music`'s example app. The behavior on
the screen should feel continuous with the other two modes: the same
pinch/pan gestures, the same tap-to-seek, the same playback cursor,
AB-loop overlay, and double-tap zoom.

Out of scope for v1:
- Tap-target visual polish (developer build shows the tap zones as a
  translucent red strip; final affordance is a separate task).
- Re-anchoring the visible page to keep the cursor in view when the
  user changes staff size, hides a staff, or applies a clef override.
- Persisting `pageIndex` across Reader open/close.

## User-visible behavior

- `Settings → Reader → Layout` and the Reader's `VisualInspector`
  Picker gain a third segment — an SF Symbol icon. Both pickers
  currently use icons only (no text labels); the new segment fits
  the same pattern. The icon defaults to `book.pages` (decision
  finalized at implementation review). Picking it switches the
  loaded score to page mode. Selection persists via the existing
  `@AppStorage` key (`readerLayoutMode`); no migration needed (the
  rawValue space simply grows).
- One page at a time fills the viewport, sized to the same width as
  vertical mode (`wrapToViewWidth: true`). The page advances to the
  next system whenever the next system would overflow the viewport's
  height. Authored `<LayoutBreak>page` still ends the page when
  `honorLayoutBreaks` is on.
- Tapping the left 12 % of the score's scroll content goes to the
  previous page. The right 12 % goes to the next. The remaining 76 %
  is the tap-to-seek area, same as the other two modes.
- When pinched to zoom > 1, the tap zones live inside the scroll
  content, so they may scroll off-screen. While off-screen they are
  inert — the user must pan or zoom out to reach them. There is no
  separate viewport-anchored page chrome in v1.
- Changing pages resets `viewportZoom` to 1 and scrolls back to the
  page's top-leading corner. Pinch state is reset to identity.
- During playback, when the cursor moves into a later page, the page
  advances automatically. Zoom is preserved across auto-advance
  (only tap-driven page changes reset zoom).
- During development, the two tap zones are filled with
  `Color.red.opacity(0.2)` so they are visually obvious. This is
  gated by a build-time flag and removed before ship.

## Architecture

### Domain — `ReaderLayoutMode`

`Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`

Add a third case:

```swift
public enum ReaderLayoutMode: String, CaseIterable, Sendable, Hashable {
    case vertical
    case horizontal
    case page
}
```

`rawValue == "page"`. The `@AppStorage` key `readerLayoutMode`
already stores the rawValue as `String`; the optional initializer in
`ReaderRootScreen` and `VisualInspectorScreen` falls back to
`.vertical` if it sees an unknown rawValue, so older builds stay
forward-compatible with someone's persisted `"page"` (they'd just
see vertical, which is the documented fallback today).

### Reader — `PagedScoreContainer`

New file: `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`

Structurally mirrors `VerticalScoreContainer`. The two containers
share enough that careful diffing of the new file against
`VerticalScoreContainer` is the cleanest review path. Differences:

- `pageIndex: Int` and `pages: [Range<Int>]` (system-index slices)
  in `@State`. The pages array is populated inside the layout
  rebuild `.task` once the new `LayoutDocument` is in hand.
- `paginate(systems:pageHeight:policy:)` is an `internal static`
  helper on `PagedScoreContainer` that re-implements the same
  greedy fit used by `SheetMusicUI.PagedScoreView.paginate`. It is
  not exposed by `SheetMusicUI`, and re-implementing inline (~30
  lines) avoids introducing a swift-sheet-music dependency surface
  change. `internal` so the Reader test target can `@testable
  import` and cover it directly.
- `ScoreScrollHost` is hosted with `alwaysBounceVertical: false`,
  `alwaysBounceHorizontal: false`, `centerVertically: true`,
  `centerHorizontally: true`. At zoom 1.0 the content size equals
  the viewport and there is no scrollable extent in either axis;
  zoom > 1 expands the scrollable extent in both axes the same way
  vertical mode expands its vertical extent.
- `expectedContentSize` closure returns `viewport.size * committedZoom`
  (no fit-to-width factor — layout is already constrained to
  `viewport.width`).
- `commitPinch` is identical in shape to `VerticalScoreContainer`'s
  but skips the fit-to-width adjustment; `targetZoom` is the
  unmodified `combined` value snapped to 1.0 at the bounce floor.
- `goToPage(_ delta: Int)` is the page-step routine called by the
  left / right tap zones:

  ```
  viewModel.resetZoom()
  committedZoom = 1.0
  pinch.magnification = 1.0
  pinch.anchor = .center
  pinch.offsetX = 0
  pinch.offsetY = 0
  pageIndex = clamped(pageIndex + delta)
  pendingScroll = .immediate(.zero)
  ```
- Playback follow:
  - Vertical mode's `autoScroll` is replaced with a `followCursor`
    routine that looks up the cursor's measure index, walks
    `pages` to find the containing page, and bumps `pageIndex`
    forward if the containing page is later than the current one.
    Zoom is not reset on auto-advance.
  - If the cursor jumps backwards (e.g. AB-loop wrap), `pageIndex`
    also moves backwards to the containing page; zoom still stays.

### Hosted view — `PagedZoomedSurface`

Lives in the same file. Mirrors `VerticalZoomedSurface`. Differences:

- Receives `pages`, `pageIndex` from the parent and computes
  `pageStartY = systems[pages[pageIndex].lowerBound].origin.y`.
- Inside `scoreSurface(document:)` the `ScoreView` is composed:

  ```
  ScoreView(document: doc, score: score, options: scoreOptions,
            playbackCursor: playbackCursor,
            playbackCursorColor: .accentColor)
      .coordinateSpace(name: "scoreSurface")
      .gesture(tapSeekGesture(document: doc))
      .frame(height: doc.size.height, alignment: .top)
      .offset(y: -pageStartY)
      .frame(height: viewport.height, alignment: .top)
      .clipped()
  ```

  The two `.frame` calls bracket the offset so SwiftUI sees the
  outer container exactly `viewport.height` tall — the inner score
  body keeps its full height so the playback cursor and tap hit-test
  stay in document coords. Clipping discards the slabs above and
  below the current page.

- Tap zones overlay sits *over* the clipped band:

  ```
  HStack(spacing: 0) {
      Color.clear.contentShape(Rectangle())
          .overlay(debugTint())
          .onTapGesture { goToPage(-1) }
      Spacer()                      // 76% — falls through to scoreSurface
      Color.clear.contentShape(Rectangle())
          .overlay(debugTint())
          .onTapGesture { goToPage(+1) }
  }
  .frame(width: viewport.width, height: viewport.height)
  ```

  The left and right are sized as `viewport.width * 0.12` via a
  fixed-width frame on each side; the middle spacer fills 76 %. The
  middle is `.allowsHitTesting(false)` for the overlay so seek taps
  pass through to `scoreSurface`'s `SpatialTapGesture`.

- `debugTint()` returns `Color.red.opacity(0.2)` when the build
  flag `READER_PAGE_TAP_DEBUG` is defined and `Color.clear` otherwise.
  The flag is set as a Swift-active-compilation condition on the
  Reader package's debug build settings (under `project.yml`).

### Reader — `ReaderRootScreen`

`Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

Add the `.page` arm to the `switch layoutMode` inside `content`:

```swift
case .page:
    PagedScoreContainer(
        score: visible,
        staffSize: viewModel.layoutModel.staffSize,
        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
        collapseMultiMeasureRests: collapseMultiMeasureRests,
        playbackCursor: viewModel.playbackCursor,
        viewModel: viewModel,
    )
```

### Settings + VisualInspector pickers

Both Picker call sites today use a `.segmented` style with **SF
Symbol icons and no text labels** (`.labelsHidden()`,
`.frame(width: 92)`):

- `SettingsSheet.swift:127-138`
- `VisualInspectorScreen.swift:54-66`

Vertical: `arrow.up.and.down`. Horizontal: `arrow.left.and.right`.

Add the third segment in both call sites:

```swift
Image(systemName: "book.pages")
    .tag(ReaderLayoutMode.page.rawValue)
```

Other SF Symbol candidates if `book.pages` looks off in the
segmented control: `doc`, `rectangle.portrait`,
`square.split.2x1`. Decide at implementation time after seeing
all three on-device.

Bump the `.frame(width: 92)` on both pickers to fit three
segments (likely `width: 132` — settle empirically). Both pickers
share the same width so they keep visual parity.

No new localization key is needed — the picker has no text labels.
The `accessibilityLabel` (if any is wired today; both call sites
currently use only `labelsHidden()`) can be addressed in the same
PR but is not blocking for the layout work.

### PiP

No change. `ScorePiPFrameRenderer` keeps its current vertical
layout regardless of the Reader's `layoutMode`, which is the
documented current behavior (PiP frame is mode-independent). Page
mode honors the Settings PiP toggle the same way vertical and
horizontal do.

## Data flow

```
   user picks .page in Settings
   ────────────────────────────►  @AppStorage "readerLayoutMode" = "page"
                                  │
                                  ▼
                    ReaderRootScreen.content (switch)
                                  │
                                  ▼
                       PagedScoreContainer
                       │
                       │ rebuildLayout (off main)
                       ▼
                LayoutDocument doc  +  pages: [Range<Int>]
                       │
                       ▼
                  PagedZoomedSurface
                       │
                       ├── tap left/right ─► goToPage(±1)
                       ├── tap on score ──► viewModel.setManualCursor
                       ├── pinch ─────────► commitPinch
                       └── playback cursor → followCursor → pageIndex++
```

## Errors and edge cases

- Layout not yet built (`document == nil`): show `Color.clear`, like
  the other containers.
- `pages.isEmpty` (defensive — shouldn't happen for a non-empty
  score): clamp `pageIndex` to 0 and show full doc with no clipping
  (effectively renders the whole score in the viewport). Logging
  here would be noise; the rebuild path always populates pages when
  systems are non-empty.
- `pageIndex >= pages.count` after a rebuild (staff size shrink
  reduces page count): clamp to `pages.count - 1`. No cursor
  re-anchor in v1.
- A single system taller than `viewport.height`: the paginator emits
  it as a single-system page; the clipping frame shows only the top
  `viewport.height` of it. v1 ships with this limitation; the user
  can drop staff size to fit.
- Tap zones falling outside the viewport while zoomed in: by design
  inert. No fallback gesture (matches the "tied to scroll content"
  requirement).
- `pendingScroll = .immediate(.zero)` on page change: page-change
  happens in tap callbacks or in the playback `onChange`, both of
  which run on main, so the `ScoreScrollHost` consumes the offset
  on the next `updateUIView` pass.

## Testing

- **Domain unit test** (`Packages/Domain/Tests/DomainTests/`):
  one `@Test` that `ReaderLayoutMode.page.rawValue == "page"` and
  one that round-trips `ReaderLayoutMode(rawValue:)` for each case.
  The `rawValue` is part of the persistence contract; a rename
  would silently drop user state.
- **Reader unit test** (`Packages/Features/Reader/Tests/`):
  extract `paginate(systems:pageHeight:policy:)` as `internal` and
  cover:
  - empty `systems` → empty `pages`
  - `pageHeight == 0` → empty `pages` (defensive)
  - single small system → single page covering its index
  - two systems, both fit → single page
  - two systems, second overflows → two pages
  - three systems with `pageBreak` on the first measure of the
    second → page boundary respected under `.honor`, ignored under
    `.ignoreAll`
  Use fake `LayoutSystem`-shaped fixtures (or the smallest real
  layout fixture already used in Reader tests).
- **Manual smoke** (preview + simulator):
  - Open a multi-page score in `.page` mode, page through with left
    / right tap, watch the debug red strip.
  - Pinch to zoom > 1, verify pan works inside the page, tap zones
    visibly shift with the scroll content.
  - Start playback, watch page auto-advance at the system boundary.
  - Tap a note in the middle band, verify seek + haptic.
  - Switch between vertical / horizontal / page from the
    `VisualInspector` — verify state survives the switch and that
    `@AppStorage` round-trips.
  - Toggle AB-loop in page mode and confirm the overlay renders
    inside the clipped page.

## Open follow-ups (post-v1)

- Final tap-target affordance (chevron buttons? page chrome?).
- Page-count chip "1 / N" along the bottom edge (the example app's
  `PagedScoreContainer` has one; defer until the tap-target visual
  is settled).
- `pageIndex` persistence in `ReaderPreferences`.
- Re-anchor the visible page to the cursor when staff size / clef
  changes invalidate pagination.

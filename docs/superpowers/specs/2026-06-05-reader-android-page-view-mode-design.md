# Android Reader — Page View Mode

- **Date:** 2026-06-05
- **Status:** Design (awaiting review)
- **Scope:** Add a page-by-page view mode to the Android Reader, at parity with the iOS Reader's page mode, reusing the existing Android vertical-scroll surface as the rendering/JNI reference.

## 1. Background

The iOS Reader has three layout modes (`Domain.ReaderLayoutMode`: `vertical`, `horizontal`, `page`). The Android Reader has historically rendered a single vertical-scroll surface only.

A separate, already-merged change (commit `3bcc8a0`, "feat(reader-android): read layoutMode pref in the Reader") landed the **wiring foundation**:

- `ReaderLayoutMode` enum in the Reader module (`Android/FolinoReaderAndroid/.../reader/ReaderLayoutMode.kt`), with `fromPref(String)` mapping the DataStore raw strings (`"vertical" | "horizontal" | "page"`) to the enum and defaulting unknown values to `VERTICAL`.
- `ReaderScreen(scoreId, title, layoutMode, onBack, …)` now branches on `layoutMode` in a single `when`. `PAGE` and `HORIZONTAL` currently fall back to the vertical-scroll surface (`ReadyScore`).
- The app layer (`MainActivity`) collects `prefs.layoutMode` (DataStore `reader.layoutMode`, default `"page"`) and injects it into `ReaderScreen`. The Reader module cannot depend on the app-level `SettingsPrefs`, so the mode is passed as a parameter.

The Settings → Layout segmented control (`vertical | horizontal | page`) and its DataStore persistence already exist; the foundation above made the Reader honor it.

**This spec covers the `PAGE` branch only.** `HORIZONTAL` remains a vertical-scroll fallback and is implemented separately (parallel session); the `when(layoutMode)` branch point is the single integration seam.

### iOS reference (page mode)

`Packages/Features/Reader/Sources/Reader/Screens/Paged/`:

- `PagedScoreContainer.swift` — lays the score out at viewport width, then `paginate(systems:pageHeight:policy:)` groups systems into pages by **viewport height** (system-aligned; never splits a system). One screen = one page.
- `PagedScoreContainer+PageNavigation.swift` — swipe (30% commit threshold + fling predicted-end; rubber-band damping at edges; velocity-matched commit/cancel curves), tap navigation, and playback-cursor auto page-turn.
- `PageTapOverlay.swift` — four tap zones: leading/trailing columns each 12% of viewport width, split 3:7 vertically (top = first/last, bottom = prev/next); shared press highlight; `n / m` badge; first-touch onboarding hint persisted via `ReaderGlobalSettingsKey.pageTapHintDismissed`.
- `PageState.swift` — observable page index + drag state; `isDragging` suppresses cursor auto-follow during a swipe.

### Android current state (vertical scroll)

`Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` `ReadyScore`:

- `nativeComputeLayout(handle, widthMM, heightMM)` (in `swift-sheet-music`, target `SheetMusicAndroidJNI`) wraps the score to `widthMM` and returns **one tall `DrawProgram` page** containing all draw commands. The `LayoutDocument` is cached in `LayoutDocumentCache` keyed by handle.
- `ScorePage(page, fontProvider, pxPerMM)` renders that tall surface inside a `verticalScroll`. Pinch zoom 1×–8× with focal-point adjustment.
- Playback cursor auto-scroll uses the shared `Domain.scrollOffsetKeepingInView` math via `FolinoReaderJNI.nativeScrollOffsetKeepingInView`, fed by `nativeCursorFrame` (returns the cursor bounding box in **mm**).

## 2. Goals / Non-goals

**Goals**

- A `PAGE` rendering path that paginates by viewport height (system-aligned), one page per screen, matching iOS page semantics.
- Full navigation parity: swipe (HorizontalPager) + 4-zone tap overlay + playback-cursor auto page-turn.
- Pinch zoom retained inside a page (iOS parity): at unit zoom swipe turns pages; while zoomed, swipe is disabled and the gesture pans within the page.
- Pagination logic **shared** with iOS (parity rule), not reimplemented divergently in Kotlin.

**Non-goals (separate work)**

- `HORIZONTAL` scroll mode (parallel session).
- Picture-in-Picture in page mode.
- Two-page spreads / landscape spreads. Single page per screen.
- Per-page Settings additions.

## 3. Decisions (confirmed)

| Question | Decision |
| --- | --- |
| Scope | `PAGE` only this task. `HORIZONTAL` keeps the vertical-scroll fallback. |
| Pinch zoom in page mode | Keep (iOS parity): unit zoom → swipe enabled; zoomed → swipe disabled, pan within page. |
| Navigation gestures | Full parity: HorizontalPager swipe + 4-zone tap (first/prev/next/last) + auto page-turn. |

## 4. Architecture

### 4.1 Where pagination lives (parity)

The Android JNI bridge (`SheetMusicAndroidJNI`) lives **inside `swift-sheet-music`**, so any logic it calls must be reachable from there. Kotlin has no access to system geometry (only the cursor frame and the opaque tall `DrawProgram`), so the page break positions must come from native code.

There are already two pagination copies in `swift-sheet-music`/Folino:

- `SheetMusicUI.PagedScoreView.paginate` (SwiftUI, `@available(macOS 15)`) — not reachable from the Android JNI target.
- Folino `PagedScoreContainer.paginate` (Feature-level, iOS) — `[Range<Int>]`, tracks `pageTopDoc` as the previous page's last-system bottom.

**Decision:** add a single Foundation-only paginator to **`SheetMusicLayout`** (reachable by `SheetMusicUI`, `SheetMusicAndroidJNI`, and Folino's iOS Reader):

```swift
// SheetMusicLayout
public enum ScorePaginator {
    /// Greedy, system-aligned pagination in document-Y. `pageTopDoc` for page 0
    /// is 0 (keeps the title/pre-system gap); for page i it is the previous
    /// page's last-system bottom. Honors `<LayoutBreak>page` unless `.ignoreAll`.
    public static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [Range<Int>]
}
```

This is the exact algorithm currently in Folino's `PagedScoreContainer.paginate`. Folino's iOS Reader is refactored to delegate to `ScorePaginator.paginate` (behavior-identical; collapses the duplicate). `SheetMusicUI.PagedScoreView` may also delegate later, but that is optional and out of scope here.

> **Review flag:** delegating Folino's iOS `PagedScoreContainer` to the shared paginator touches iOS Reader code. The logic is identical, so behavior is unchanged, but call this out for review.

### 4.2 New JNI — page break offsets

```swift
// SheetMusicAndroidJNI / JNISymbols.swift
/// Page break offsets (document-Y, **mm**) for the cached layout, paginated by
/// `pageHeightMM`. Returns `[0, top₁, top₂, …, contentBottom]` (length = pageCount + 1).
/// Empty when the handle is unknown or the document has no systems.
public func nativePageBreaks(scoreHandle: Int64, pageHeightMM: Double) -> [Double]
```

- Reads `LayoutDocumentCache[scoreHandle]` (populated by the existing `nativeComputeLayout`, so the breaks are computed against exactly the surface that is rendered).
- Converts `pageHeightMM` → pt, runs `ScorePaginator.paginate`, derives the document-Y boundaries from the returned ranges, converts pt → mm (consistent with `nativeCursorFrame`, which is mm).
- **No `DrawProgram` format change.** The existing single tall page is reused.

Wire format: return as a `Double[]` over swift-java (or a length-prefixed `Data` if the array marshaling needs it — match whatever existing JNI symbols already do for primitive arrays).

### 4.3 Rendering — band-clip of the existing tall surface

Each page `i` renders the **same tall `ScorePage`**, translated up by `breaks[i]` and clipped to the band `[breaks[i], breaks[i+1]]`, inside a viewport-height white box (top-aligned):

- Band height (doc-mm) = `breaks[i+1] − breaks[i]`, in px = `× fitPxPerMM × scale`.
- Because the breaks are system-bottom aligned, **no sliver of the next page's first system leaks** into the band — matching iOS's per-page sub-document rendering visually, without emitting per-page draw commands.
- `HorizontalPager` only composes the current page and its immediate neighbors, so at most ~3 tall-surface canvases exist at once — the same per-canvas cost as today's vertical mode (bounded, not `O(pageCount)`).
- The `PlaybackCursorOverlay` is offset/clipped identically so the cursor lands in the right band.

This keeps the swift-sheet-music change minimal (one JNI + one shared paginator) and reuses the proven `ScorePage` renderer.

### 4.4 Navigation (Compose, Android idioms + iOS parity)

`PagedScore` composable (new, in the Reader module), selected by the existing `when(layoutMode) { PAGE -> … }` branch:

- **Swipe** — `HorizontalPager` over `pageCount`. `userScrollEnabled = (scale == 1f)` so swipe turns pages only at unit zoom; while zoomed the pager is locked and the gesture pans within the page (reusing the vertical-mode pinch/pan handling per page). Commit at 30% of width or fling predicted-end past 30%; edge rubber-band damping; velocity-matched settle. (HorizontalPager's default fling/snap approximates this; tune `pagerSnapDistance` / `SnapFlingBehavior` to hit the 30% feel.)
- **4-zone tap overlay** — leading/trailing columns 12% of width, split 3:7 (top = first/last, bottom = prev/next). Shared press highlight across all zones; `n / m` page badge; first-touch onboarding hint (dashed border) → persisted via a new DataStore key `reader.pageTapHintDismissed`, threaded into `ReaderScreen` the same way as `layoutMode`. Placement mirrors iOS; styling uses Material affordances.
- **Auto page-turn** — collect `currentCursor` → `nativeCursorFrame` → cursor `y` (mm) → find the page whose `[breaks[i], breaks[i+1])` contains it → `pager.animateScrollToPage`. Suppressed while the user is dragging the pager (iOS `isDragging` guard equivalent); re-run once on drag end if the cursor advanced during the swipe.

### 4.5 Pinch zoom within a page

Reuse the vertical-mode focal-adjusted offset + scroll handling, scoped to the current page band. At unit zoom, `HorizontalPager` swipe is enabled; above unit zoom, swipe is disabled and vertical/horizontal pan applies within the page. Returning to unit zoom re-enables swipe.

## 5. State

`PagedScore` owns:

- `pagerState` (`rememberPagerState { pageCount }`) — current page + swipe progress.
- `scale` / scroll offsets — per the vertical-mode pinch model, reset to unit on page turn.
- `pageBreaksMm: DoubleArray` — from `nativePageBreaks`, recomputed when `(scoreHandle, viewportHeightMm, layout width)` changes (a `LaunchedEffect` keyed on those).

`pageCount = max(1, pageBreaksMm.size - 1)`. Page index is clamped when the count shrinks (e.g. rotation).

The onboarding-hint dismissed flag lives in DataStore (`reader.pageTapHintDismissed`), parallel to iOS.

## 6. Cross-repo work & build/pin steps

Both repos are edited in **worktrees** (per project convention).

1. **swift-sheet-music** (worktree off ssm local `main`, which carries the bounded-scroll fix — not the `chore/ci-manual-only-preflight` branch):
   - Add `ScorePaginator` to `SheetMusicLayout`.
   - Add `nativePageBreaks` to `SheetMusicAndroidJNI`.
   - Regenerate swift-java jextract Java bindings for the new symbol.
   - Commit; this becomes the new pin.
2. **Folino** (worktree):
   - Re-pin `swift-sheet-music` (`Package.resolved` / `project.yml` / the consuming `Package.swift`) to the new commit.
   - Rebuild the Reader `.so` and Java bindings via `Scripts/android-build-reader-libs.sh`; stage `jniLibs/` + `java-generated/`.
   - Implement `PagedScore` + tap overlay + auto page-turn; thread `pageTapHintDismissed` from the app layer.
   - (Optional, flagged) Delegate Folino iOS `PagedScoreContainer.paginate` to `SheetMusicLayout.ScorePaginator`.

Watch the documented pin/`.so` drift pitfalls: a stale `Package.resolved` or stale `.so` produces compile/link failures unrelated to the source. Resolve → rebuild `.so` → verify symbol presence.

## 7. Testing

- **SheetMusicLayout** — unit tests for `ScorePaginator.paginate`: empty input, single system, exact-fit boundaries, `<LayoutBreak>page` honored vs `.ignoreAll`, `pageTopDoc` continuity (page `i+1` top == page `i` bottom). Reuse/extend the existing iOS pagination test cases so iOS and the shared paginator are covered by one suite.
- **JNI** — `nativePageBreaks` returns `[]` for unknown handle; for a known multi-system layout, breakpoints are monotonic, start at 0, end at content bottom, and align with system bottoms.
- **Android (manual, Pixel)** — page turn via swipe and via each tap zone; auto page-turn during playback; pinch zoom locks swipe and pans; onboarding hint shows once then never again; rotation re-paginates without crashing; `horizontal` pref still falls back to vertical.
- Android change ships with `installDebug` + launch verification on a physical Pixel (per project convention).

## 8. Risks / open questions

- **HorizontalPager fling vs iOS curve.** Compose's pager snapping won't be byte-identical to the iOS 30%/velocity model. Acceptable: match the *threshold/feel*, not the exact curve. If it feels off, fall back to a custom `draggable` + offset (the iOS mechanics port directly).
- **Page-band width gutter.** iOS deducts a 12pt horizontal gutter for page content. v1 reuses the full viewport width (same wrap as vertical) for simplicity; revisit if the page content feels flush to the edges.
- **Cursor-frame ↔ break unit consistency.** Both are mm; verified against `ReadyScore`'s existing `frame.y * fitPxPerMM` usage. Add an assertion/test so a future unit change in either JNI is caught.
- **Large scores.** Band-clip composes ≤3 tall canvases via the pager; if profiling shows the tall-surface redraw is costly for very long scores, the fallback is a multi-page `DrawProgram` (per-page commands) — deferred unless measured.

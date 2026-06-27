# Reader auto-follow & page-turn-button opt-out — Design

**Date:** 2026-06-27
**Status:** Approved (design); pending spec review
**Area:** `Packages/Features/Reader`, `Packages/Domain` (settings keys)

## Motivation

During playback the Reader follows the playhead automatically: in `vertical` /
`horizontal` modes it auto-scrolls, in `page` mode it auto-turns the page. Some
users want to read at their own pace and keep the score still while playback
runs. Likewise, the `page`-mode tap-zone navigation (the four "page-turn
buttons") is always visible, and some users want to hide it.

This adds two opt-out preferences, surfaced in the Reader's visual inspector.

## Settings

Two new global, cross-score preferences, persisted via `@AppStorage` keyed by
new `ReaderGlobalSettingsKey` entries. Both **default ON**, so existing
behavior is preserved and no migration is needed.

| Constant | Raw key | Type / default | Scope |
| --- | --- | --- | --- |
| `ReaderGlobalSettingsKey.autoFollowEnabled` | `readerAutoFollowEnabled` | `Bool` / `true` | Score only |
| `ReaderGlobalSettingsKey.pageTurnButtonsVisible` | `readerPageTurnButtonsVisible` | `Bool` / `true` | Score + PDF |

- **`autoFollowEnabled`** governs playback-driven auto-scroll (`vertical` /
  `horizontal`) and auto-page-turn (`page`). PDFs have no playback cursor, so
  this preference does not apply to PDFs.
- **`pageTurnButtonsVisible`** governs whether the `page`-mode tap-zone overlay
  (`TapOverlay`) is shown. The overlay is rendered by the shared
  `PagedReaderSurface`, used by both the score and PDF paged readers, so this
  one flag applies to both.

## UI — Visual inspector

### Score — `VisualInspectorScreen`

Add two rows to the **General** section, after `seekBarRow`:

1. **Auto-follow toggle** (always visible). The label switches dynamically on
   the current layout mode (read from the existing `layoutModeRaw`
   `@AppStorage`):
   - `vertical` / `horizontal` → **"自動スクロール"** (`reader.inspector.autoScroll`)
   - `page` → **"自動ページめくり"** (`reader.inspector.autoPageTurn`)

   It is a single shared preference; only the label changes with the mode.

2. **Page-turn-buttons toggle** — shown **only when `layoutMode == .page`**.
   Label: **"ページめくりボタン"** (`reader.inspector.showPageTurnButtons`).

### PDF — `PDFLayoutInspectorScreen`

Add one row:

- **Page-turn-buttons toggle** — shown **only when the PDF layout is `page`**.
  Same `pageTurnButtonsVisible` key and label as the score inspector. (No
  auto-follow row — PDFs have no playback.)

  This requires the PDF inspector to know the current PDF layout mode. It
  already reads/writes the layout via the shared `layoutMode` key, so the row
  is gated on the same value (resolved through `pdfLayoutMode` semantics — a
  stale `horizontal` selection resolves to `page` for PDFs).

## Behavior

### Auto-follow OFF

- **During playback**, the score does not scroll (vertical/horizontal) or turn
  the page (page) to follow the playhead. The user navigates manually.
- **Manual navigation still keeps the target in view.** Tap-to-seek, measure
  step (forward/back), seek-to-start, and seek-bar scrubbing continue to bring
  the seeked-to position on screen. Only the continuous, playback-driven follow
  is suppressed.

The distinguishing signal already exists: the lookahead anchor cursors
(`scrollAnchorCursor` / `pageAnchorCursor`) are non-`nil` **only** during
continuous playback (`isPlaying && scrubCursor == nil`). Manual navigation
arrives with the anchor `nil`. So the gate is: when `autoFollowEnabled` is
`false`, skip the follow **only when the anchor cursor is non-`nil`**; let the
existing keep-in-view path run for manual navigation.

### Page-turn-buttons OFF

- The `page`-mode tap-zone overlay is not rendered (no tap targets, no
  onboarding hint, no page badge from the overlay).
- **Swipe-to-turn still works** (separate gesture in `PagedReaderSurface`), and
  auto-page-turn still works when `autoFollowEnabled` is ON. Hiding the buttons
  only removes the tap affordance.

## Wiring

### Domain

- `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`: add the two
  `ReaderGlobalSettingsKey` constants with doc comments (default semantics noted
  at the `@AppStorage` sites).

### `ReaderRootScreen`

- Add two `@AppStorage` reads: `autoFollowEnabled` (default `true`) and
  `pageTurnButtonsVisible` (default `true`).
- Pass `autoFollowEnabled` to `VerticalScoreContainer`,
  `HorizontalScoreContainer`, and `PagedScoreContainer`.
- Pass `showsPageTurnButtons: pageTurnButtonsVisible` to `PagedScoreContainer`
  and `PagedPDFContainer`.

### Score containers — follow gating

- **`VerticalScoreContainer` / `HorizontalScoreContainer`**: add
  `let autoFollowEnabled: Bool`. In the `.onChange(of: [playbackCursor,
  scrollAnchorCursor])` handler, return early when
  `!autoFollowEnabled && scrollAnchorCursor != nil`. Otherwise call `autoScroll`
  unchanged (manual keep-in-view preserved).
- **`PagedScoreContainer`**: add `let autoFollowEnabled: Bool`. In the
  `.onChange(of: [playbackCursor, pageAnchorCursor])` handler, return early when
  `!autoFollowEnabled && pageAnchorCursor != nil`. Also gate the post-swipe
  catch-up in `onSwipeEnded` (`followCursor(playbackCursor)`), which only fires
  to chase active playback — skip it when `!autoFollowEnabled`.

### Tap-zone visibility — shared surface

- **`PagedReaderSurface`**: add `let showsTapZones: Bool`. In `body`,
  conditionally include `tapOverlay()` (e.g. wrap in `if showsTapZones`).
- **`PagedZoomedSurface`** (score adapter) and **`PagedPDFContainer`**'s surface
  usage: thread `showsTapZones` down from the container's
  `showsPageTurnButtons`.
- The `pageTapHintDismissed` onboarding flag is unaffected; when the overlay is
  hidden there is simply nothing to hint.

### PDF inspector

- **`PDFLayoutInspectorScreen`**: add the page-turn-buttons toggle, gated on the
  PDF layout being `page`. Reads/writes `pageTurnButtonsVisible`.

## Localization

New keys in the Reader module's `Localizable.xcstrings` (EN + JA), following the
existing `reader.inspector.*` convention:

| Key | EN | JA |
| --- | --- | --- |
| `reader.inspector.autoScroll` | Auto-scroll | 自動スクロール |
| `reader.inspector.autoPageTurn` | Auto page turn | 自動ページめくり |
| `reader.inspector.showPageTurnButtons` | Page-turn buttons | ページめくりボタン |

## Non-goals / out of scope

- No per-score override; these are global preferences (consistent with the
  neighboring `collapseMultiMeasureRests` / `showInvisibleElements` /
  `showSeekBarEnabled` settings).
- No change to the auto-scroll / page-turn math or lookahead constants — only
  whether the follow runs.
- No Settings-sheet mirror of these toggles (they live in the visual inspector
  only, per request). A future follow-up could mirror them in Settings.
- No Android port in this spec (parity follow-up tracked separately; the gating
  is shared-logic-friendly but the Android Reader wiring is its own task).

## Testing & verification

- The added logic is boolean gating inside SwiftUI views; the underlying
  scroll-offset helpers (already covered by Domain tests) are untouched.
- Build + run the Reader package tests (`xcodebuild test -scheme Reader
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`) to confirm no
  regression.
- Preview-render the visual inspector in both `page` and non-`page` modes to
  confirm the dynamic label and the conditional page-turn-buttons row.
- Manual device smoke (user-driven, per project workflow): toggle each setting
  and confirm playback no longer follows / tap zones disappear, while manual
  seek still recenters and swipe still turns pages.

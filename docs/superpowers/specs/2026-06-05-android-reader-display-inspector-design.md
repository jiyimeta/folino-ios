# Android Reader — Display Inspector (full scope)

**Date:** 2026-06-05
**Status:** Design approved, pending spec review
**Platforms:** Android (new). iOS display inspector already exists and is the parity reference.

## Goal

Bring the iOS Reader's *display inspector* (visual / layout settings panel) to the
Android Reader, modeled structurally on the already-shipped Android *playback
inspector* (dense `ModalBottomSheet`). The Android Reader today renders with a
hardcoded layout (vertical-only, fixed staff size, A4 page dimensions) and exposes
**no** display settings. This work wires every display setting the iOS inspector
exposes — including all three layout modes — through shared swift-sheet-music code.

### Parity governance

- **Logic is shared.** All layout/score-transformation logic lives in
  swift-sheet-music and is consumed by both iOS (Swift) and Android (via JNI). We do
  **not** reimplement layout behavior as a divergent Android code path.
- **UI placement is Android-idiomatic.** Trigger lives in the `TopAppBar` (view
  options at top, transport at bottom); presented as a dense `ModalBottomSheet`. The
  *content* (which settings exist, what they do) is at iOS parity; the *placement* is
  Android.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Scope | Full — all iOS display settings **including** the 3 layout modes |
| Trigger placement | `TopAppBar` right-side action icon |
| Persistence | Session-transient (StateFlow only; resets when Reader closes), matching the Android playback inspector precedent |
| Clef picker presentation | Glyph tiles (SMuFL music-font glyphs), faithful to iOS `ClefMenu` |
| iOS "Show seek bar" toggle | **Excluded** — Android transport bar is always visible |

## Settings inventory (iOS → Android)

**General section**

| Setting | iOS source | Android control | Render effect |
| --- | --- | --- | --- |
| Layout mode | `ReaderLayoutMode` (vertical/horizontal/page) | 3-way `SegmentedButton` | Chooses render container + `ScoreViewOptions`/availableWidth |
| Staff size (8–28 pt) | `LayoutSettingsModel.staffSize` | Slider/stepper | `ScoreViewOptions.staffSize` (+ `systemGap = staffSize*1.25`) |
| Follow line/page breaks | `honorLayoutBreaks` | Toggle | `breakPolicy = .honor / .ignoreAll` |
| Collapse multi-measure rests | `collapseMultiMeasureRests` | Toggle | `multiMeasureRest = .collapse(threshold) / .disabled` |
| Show hidden elements | `showInvisibleElements` | Toggle | `showsInvisibleElements` |

**Parts section** (per part, per staff)

| Setting | iOS source | Android control | Render effect |
| --- | --- | --- | --- |
| Staff visibility | `hiddenStaves: Set<StaffAddress>` | Eye toggle | `Score.filtered(hidingStaves:)` before layout |
| Clef override | `staffClefOverrides: [StaffAddress: String]` | Glyph-tile picker | `Score.applying(clefOverrides:)` before layout |

## Architecture

```
Android ReaderViewModel (Kotlin, StateFlow display state)
   │  encode LayoutOptionsWire blob on any change (debounced)
   ▼
SheetMusicJNI.nativeComputeLayout(handle, wMM, hMM, optionsBlob)   ← swift-sheet-music
   ▼
LayoutBridge: decode options → score.applying(clefOverrides).filtered(hiddenStaves)
              → ScoreViewOptions per mode → LayoutEngine.layout
              → (page mode) paginate → multi-page DrawProgram
   ▼
DrawProgram wire (already supports a page list)
   ▼
Compose ReadyScore: vertical scroll | horizontal scroll | HorizontalPager
```

## Repo A — swift-sheet-music changes

Work in a dedicated worktree on the swift-sheet-music clone
(`~/Developer/Personal/swift-packages/swift-sheet-music`).

### A1. Lift Score transforms into shared code

Move these two `Score` extensions out of the iOS Reader Feature and into
swift-sheet-music (`SheetMusicCore`, an `Score+DisplayTransforms.swift` or similar):

- `Score.filtered(hidingStaves: Set<StaffAddress>) -> Score`
  (currently `Packages/Features/Reader/Sources/Reader/Score+Filtered.swift`)
- `Score.applying(clefOverrides: [StaffAddress: String]) -> Score`
  (currently `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift`)

Both already depend **only** on `SheetMusicCore` types (`Score`, `Part`, `Staff`,
`Clef`, `StaffAddress`) — no Domain, no Feature dependency — so the move is clean.
Make them `public`. The iOS Reader deletes its private copies and calls the shared
versions (it already imports `SheetMusicCore` via Domain re-export). Move the
accompanying unit tests into swift-sheet-music's test target.

> This is a shared-logic refactor that ripples into the iOS Reader Feature (call
> sites unchanged in shape, only the definition relocates). Flagged for spec review.

### A2. Lift pagination into shared code

The page-mode paginator currently lives in iOS `PagedScoreContainer.paginate(systems:pageHeight:policy:) -> [Range<Int>]`. Lift it into swift-sheet-music
(`SheetMusicLayout`, e.g. `LayoutPaginator.paginate(...)`) so both the iOS Paged
container and the Android JNI bridge produce identical page boundaries. iOS Paged
container calls the shared version.

### A3. `LayoutOptionsWire` codec (new, shared)

A binary codec mirroring the existing `ScoreCursorCodec` / `StaffAddressCodec`
pattern, used to pass display settings across the JNI boundary. Encoded fields:

- `layoutMode: UInt8` — 0 = vertical, 1 = horizontal, 2 = page
- `staffSize: Double`
- `honorLayoutBreaks: UInt8`
- `collapseMultiMeasureRests: UInt8`
- `showsInvisibleElements: UInt8`
- `hiddenStaves: [StaffAddress]` (reuse `StaffAddressCodec`)
- `clefOverrides: [(StaffAddress, String)]`

Provide a Swift decoder (in `SheetMusicAndroidJNI`) and a Kotlin encoder (in
`SheetMusicAndroid`). Round-trip unit tests on both sides.

### A4. Extend the JNI layout entry point

Change `nativeComputeLayout` to accept the options blob:

```
nativeComputeLayout(scoreHandle: Int64, pageWidthMM: Double, pageHeightMM: Double,
                    optionsBlob: Data) -> Data
```

(Kotlin: `SheetMusicJNI.nativeComputeLayout(scoreHandle, pageWidthMM, pageHeightMM, optionsBlob: ByteArray): ByteArray`.)

Swift side (`LayoutBridge+Document.swift` / `JNISymbols.swift`):

1. Decode `LayoutOptionsWire`.
2. `let prepared = score.applying(clefOverrides:).filtered(hidingStaves:)`.
3. Build `ScoreViewOptions` per mode:
   - **vertical**: `wrapToViewWidth: true`, `includeTitleFrame: true`, availableWidth = page width (pt).
   - **horizontal**: `wrapToViewWidth: false`, `includeTitleFrame: false`, availableWidth = `LayoutEngine.naturalContentWidth(score:options:)`.
   - **page**: `wrapToViewWidth: true`, `includeTitleFrame: true`, availableWidth = page width (pt). After layout, `LayoutPaginator.paginate(systems:pageHeight:policy:)` → emit one `EncodablePage` per page range, each with the per-page Y offset baked into draw coordinates.
   - All modes: apply `staffSize`, `systemGap = staffSize*1.25`, `breakPolicy`, `multiMeasureRest`, `showsInvisibleElements`.
4. Vertical/horizontal emit a single page; page mode emits N pages. The DrawProgram
   wire already carries a page list (`EncodablePage { widthMM, heightMM, commands }`).

> The default/legacy call (no options) is removed; the only call site is the Android
> Reader, which always passes a blob. Keep one entry point.

### A5b. Parts/staves metadata accessor (new JNI)

Add a lightweight JNI accessor that returns, for a score handle, the parts/staves
descriptor the Android Parts section needs: per part, the staff count and any staff
display names. Encode as a small `Data` blob (own codec) so Kotlin can build the
`StaffAddress` list for the inspector without parsing the draw program.

### A5. Build artifacts

Rebuild the Android `.so` from the swift-sheet-music worktree, regenerate the
swift-java jextract bindings (the `nativeComputeLayout` signature changed). Verify the
generated `SheetMusicJNI` Kotlin/Java surface matches.

## Repo B — Folino Android changes

Work in a dedicated Folino worktree. Copy prebuilt `jniLibs`/`java-generated` from the
primary checkout where possible to avoid a full cross-compile, then rebuild only what
changed (per the established Android worktree flow).

### B1. Display state in `ReaderViewModel.kt`

Add session-transient `StateFlow`s:

- `layoutMode: StateFlow<ReaderLayoutMode>` (Kotlin enum: VERTICAL/HORIZONTAL/PAGE)
- `staffSize: StateFlow<Double>` (default 28, range 8–28)
- `honorLayoutBreaks: StateFlow<Boolean>` (default true)
- `collapseMultiMeasureRests: StateFlow<Boolean>` (default false)
- `showInvisibleElements: StateFlow<Boolean>` (default false)
- `hiddenStaves: StateFlow<Set<StaffAddress>>`
- `clefOverrides: StateFlow<Map<StaffAddress, String>>`

Plus setters. Any change re-encodes the `LayoutOptionsWire` blob and re-invokes
`nativeComputeLayout` (debounced, off the main thread, replacing the current
`load()`-time call). The viewport `pageWidthMM`/`pageHeightMM` continue to feed the
call; page mode uses the live viewport size.

Kotlin needs a small `StaffAddress` value type (partIndex, staffIndexInPart) and a
parts/staves descriptor so the UI can enumerate staves. Source that descriptor from
the parsed score via a **new** lightweight JNI accessor (a parts/staves metadata query
returning, per part, the staff count and any staff display names) rather than parsing
the draw program. Define this accessor in swift-sheet-music alongside A4.

### B2. `DisplayInspectorSheet.kt` (new Compose)

Mirror `PlaybackInspectorSheet.kt`'s dense layout (icon + fixed-width label + control +
readout; collapsible sections via `rememberSaveable`).

- **General**: `SegmentedButton` row for layout mode; staff-size slider with "N pt"
  readout; three toggles (honor breaks, collapse rests, show invisible).
- **Parts**: `LazyColumn`; per part a header, then per staff a row with an eye
  visibility toggle and a clef-override control that opens a glyph-tile picker.
- **Clef glyph tiles**: render SMuFL codepoints (mirrored from iOS `ClefMenuChoice`)
  using the bundled music font from `bundledFontProvider`; current clef highlighted;
  a "Reset" affordance when an override is effective. 14 clef choices grouped
  treble / bass / C / percussion, matching iOS.

### B3. Trigger + presentation in `ReaderScreen.kt`

Add a `TopAppBar` `actions { IconButton(...) }` (display icon, e.g. a layout/format
glyph distinct from the bottom-bar `Tune`) toggling a `showDisplayInspector` state →
`ModalBottomSheet` (full height, `skipPartiallyExpanded = true`), same pattern as the
playback inspector.

### B4. Three render modes in `ReadyScore`

Branch on `layoutMode`:

- **vertical**: existing path (fit-width, pinch zoom, vertical scroll), now driven by
  the recomputed program.
- **horizontal**: render the single wide page with horizontal scroll only (no
  fit-width factor; pinch zoom optional, vertical centered). Cursor follow parks the
  measure leading edge near screen-left (mirror iOS horizontal follow).
- **page**: `HorizontalPager` over the multi-page program (discrete pages, swipe to
  turn). Cursor follow jumps to the page containing the cursor.

Keep the existing playback cursor overlay and keep-in-view JNI math; extend follow
behavior per mode.

### B5. Localization

Add Android string resources mirroring iOS keys: `reader.preferences.*`,
`reader.inspector.section.general` / `.parts`, the 14 `reader.preferences.clef.choice.*`,
`reader.preferences.clef` / `.clef.resetDefault`, and a display-settings toolbar label.
Provide en / ja / ko / zh-Hans / zh-Hant to match iOS coverage.

### B6. Re-pin

Bump the swift-sheet-music pin in the Reader `Package.swift` and `project.yml` (iOS
side) and the Android Gradle/`.so` artifacts to the new swift-sheet-music revision.

## Testing

- **swift-sheet-music**: `LayoutOptionsWire` round-trip codec tests; relocated
  `filtered` / `applying` / paginator tests pass in the swift-sheet-music test target;
  a layout-bridge test asserting page-mode emits N pages and horizontal emits a single
  wide page.
- **iOS**: Reader still builds after the transform/paginator relocation; existing
  Reader behavior unchanged (Folino app build + Reader package tests).
- **Android**: app builds; install + launch on a Pixel device (per parity rule) and
  manually verify: mode switching (vertical/horizontal/page), staff size, the three
  toggles, per-staff hide, clef override (glyph tiles), and that pinch/scroll still
  behave per mode.

## Out of scope / deferred

- Persisting display settings across sessions (would mirror iOS `ReaderPreferences`
  via DataStore) — deferred per the session-transient decision.
- iOS "Show seek bar" toggle — N/A on Android.
- Any new layout *capability* beyond the three existing iOS modes.

## Risk notes

- **JNI signature change** breaks the generated bindings until regenerated (A5) — the
  `.so` + jextract regen is a known drift source; rebuild deliberately.
- **Page-mode coordinate baking**: each `EncodablePage`'s draw commands must be offset
  so the page's first system sits at the page top (iOS clips with
  `pageStartY` = previous page's last-system bottom). Get the per-page Y origin right.
- **Parts/staves descriptor** for the UI needs a reliable source from the parsed score;
  define the JNI accessor before building the Parts section.

# Android Annotation (書き込み) — Design

**Status:** Draft for review
**Date:** 2026-07-13
**Author:** Kiichi Ito (with Claude)
**Related:** `2026-06-27-pencil-annotation-m2b-horizontal-paged-design.md` (iOS annotation), `docs/engineering/module-architecture.md`

## 1. Goal & context

Folino's freehand annotation feature ("書き込み") — draw ink over a musical score, ink re-flows with
the layout, one annotation layer per score — currently exists on **iOS only** (SwiftUI + PencilKit).
This spec plans bringing it to **Android** (Jetpack Compose), at parity with iOS behavior, while
honoring the project's two cross-platform rules:

- **Logic/behavior → shared Swift.** Business logic, domain rules, and persistence semantics must be
  identical on both platforms and implemented once in shared Swift called over JNI — never
  re-implemented as a divergent Kotlin path.
- **UI/UX placement → Android idioms.** Control placement, icons, copy, and gestures follow Android
  conventions; only the *content* stays at iOS parity.

The feature also lays the groundwork for a **future** "share an annotated score" capability
(export/import an annotated score between users, cross-platform). That future feature needs a single
cross-platform interchange format for ink — which this spec defines and adopts on **both** platforms
now.

### Non-goals (this spec)

- The actual "share an annotated score" export/import feature and any UI for it. (Future spec.)
- PDF annotation on Android — Android has **no PDF reader** yet (a separate unbuilt feature). Android
  annotation scopes to score modes only.
- Live iOS↔Android cloud sync of annotations — Android has no CloudKit backend; sync is a potential
  future built on the shared format, not part of this work.
- Text boxes (`TextBoxAnchor`) — the iOS model carries them but the Reader always writes
  `textBoxes: []`. Android will preserve/round-trip the field but not author text boxes in v1.
- Range-anchoring / stretch-to-fit wide marks (`project_annotation_range_anchoring`) — separate future
  idea; v1 keeps the rigid single-anchor + translate/uniform-scale model on both platforms.

## 2. Decisions (locked with the user)

| # | Decision | Choice |
|---|---|---|
| D1 | Stroke format & cross-platform strategy | **One shared, platform-neutral stroke format** used by both platforms. |
| D2 | Android layout surfaces in v1 | **All three score modes**: Vertical scroll, Horizontal scroll, Paged. (No PDF — Android has none.) |
| D3 | Tool palette | **Standard**: pen, highlighter, eraser, color palette, stroke width, undo/redo. |
| D4 | Drawing input | **Finger + stylus both draw.** One-finger/stylus draws; two-finger navigates (pan/zoom). |
| D5 | iOS format migration timing | **Migrate iOS to the neutral format now** (the install base is tiny — feature is ~2 days old, ~dozens DAU — so this is the cheapest possible migration window). |
| D6 | iOS migration method | **One-time full migration** of all existing layers to neutral via the validated codec (safe at this scale), with the legacy PencilKit decoder retained permanently. |
| D7 | Delivery phasing | **Ship the iOS format migration first, as an independent iOS release**, decoupled from the (weeks-long) Android build. |

## 2.1 Phasing

The work splits into two independently shippable phases:

- **Phase 1 — iOS format migration (ship now).** Define the neutral `InkStroke` format + codec, add the
  iOS `PKDrawing ↔ InkStroke` codec, retain the legacy decoder (read-both), run the one-time migration,
  write neutral thereafter, and add the CloudKit preserve-don't-clobber insurance. **No user-visible
  change** — the annotation UX is identical; only the at-rest storage format changes. Rationale: the
  install base is tiny *now*, so this is the cheapest migration window, and it production-validates the
  neutral format before Android commits to it.

  **Scope minimization for Phase 1:** iOS only swaps the **persistence codec at the store boundary**
  (encode the already-baked per-stroke `PKDrawing` ↔ `InkStroke`). The anchoring core stays
  PencilKit-typed and **unchanged** — the neutralization refactor (§5.1), which only matters for sharing
  the core with Android, is deferred to Phase 2. This keeps Phase 1 low-risk and fast.

- **Phase 2 — Android annotation (later).** Everything else in this spec: neutralize `AnnotationAnchoring`,
  ssm anchor primitives, androidx.ink capture/render, Room persistence, tool palette, Reader
  integration. Built on the Phase-1-validated format.

The sections below describe the full (both-phase) design; §9 + §4 + §10 (codec tests) are the Phase 1
surface.

## 3. Architecture overview

The feature stratifies cleanly along the shared-vs-platform boundary. What is **logic** (data model,
anchoring math, persistence policy, stroke codec) is written once in shared Swift; what is **platform
UI/IO** (ink capture, rendering, tool palette, native persistence backend) is per-platform.

| Layer | Change | Summary |
|---|---|---|
| **Domain** (shared, Foundation-only) | additive | Existing `AnnotationLayer` / `DrawingAnchor` / `MusicalAnchor` / `AnnotationStore` are reused unchanged in shape. **New: neutral stroke format `InkStroke` + its binary codec.** |
| **Reader package — shared anchoring core** (shared) | refactor | Neutralize `AnnotationAnchoring` so it operates on `InkStroke` (no PencilKit). Both platforms call it. iOS keeps a thin `PKStroke ↔ InkStroke` adapter. |
| **swift-sheet-music (ssm)** (shared, cross-repo) | additive | Add `nativeResolveAnchor` / `nativeAnchorReferencePoint` JNI entry points (mirroring the existing `nativeNearestCursor`) so the shared anchoring core can reach `LayoutDocument` on Android. |
| **FolinoReaderJNI** (Android bridge) | additive | New stateless JNI entry points hosting the shared capture (bake) and display (transforms) over `InkStroke`. |
| **Android Kotlin** (platform UI) | new (largest) | androidx.ink wet capture + `CanvasStrokeRenderer` dry overlay, tool palette, `ReaderViewModel` annotation state, Room `annotation_layers` backend. |
| **iOS** (platform UI + migration) | migrate | `PKDrawing ↔ InkStroke` codec, one-time storage migration to neutral, retain legacy decoder. PencilKit UI unchanged apart from feeding the neutral codec. |

**Feasibility is confirmed, not assumed.** The hard part — resolving a drawn point to a musical
position on Android — is the exact shape of the shipping `nativeNearestCursor` (tap → seek) bridge:
`SheetMusicAndroidJNI/NearestCursorBridge.swift` already does "document-mm point → cached
`LayoutDocument` → shared entry point → encoded bytes." The anchor primitives `resolveAnchor(at:)` and
`anchorReferencePoint(...)` are `public` on `LayoutDocument` in the Foundation-only, Android-compatible
`SheetMusicLayout` core (`SheetMusicLayout/Anchor/{ResolveAnchor,AnchorReferencePoint}.swift`). No
fundamental blocker.

## 4. Data model & neutral stroke format

### 4.1 Reused unchanged (Domain, Foundation-only)

- `AnnotationLayer { id, scoreItemID, drawings: [DrawingAnchor], textBoxes: [TextBoxAnchor], updatedAt }`
  — one layer per score.
- `DrawingAnchor { id, kind: DrawingAnchorKind, encodedDrawing: Data }`. `kind` = `.musical(MusicalAnchor)`
  for reflowable score. `encodedDrawing` stays an **opaque per-stroke blob** — its *bytes* change from a
  PencilKit archive to the neutral `InkStroke` encoding; the container shape is unchanged.
- `MusicalAnchor { measureIndex, tickInMeasure, partIndex, staffIndexInPart, dxSp, verticalOffsetSp }`
  — layout-agnostic musical position. (ssm's `ResolvedAnchor` mirrors these six fields, so the
  conversion is 1:1.)
- `AnnotationStore` protocol — CRUD one layer per score id.

### 4.2 New: `InkStroke` neutral format (Domain)

A single stroke, encoded platform-neutrally so both PencilKit and androidx.ink can round-trip it
without visible fidelity loss. Geometry is stored **anchor-relative, in staff-space (sp) units** (origin
= the stroke's anchor point), matching the iOS baking convention.

Per-stroke binary blob (base64 inside the existing layer JSON payload). Header + Structure-of-Arrays:

- **Header:** `formatVersion: u8`, `tool: u8` (pen / highlighter — blend mode is *implied by tool*,
  mapped per platform to `PKInkType` ↔ `StockBrushes`, never a raw blend enum), `colorRGBA: u32`
  (canonical light-appearance sRGB; each platform applies its own dark-mode adaptation),
  `baseWidthSp: f32`, `opacity: f32`, presence flags, `count: u32`.
- **Arrays (length `count`):**
  - `x[], y[]` — `f32`, anchor-relative sp, **dense on-curve samples** (~0.5–1 sp arc-length spacing;
    on iOS via `PKStrokePath.interpolatedPoints`, not B-spline control points — dense samples re-ingest
    convergently into either engine's smoothing).
  - `width[]` — `f32` sp, the **resolved rendered width profile** (the cross-platform fidelity carrier:
    the foreign platform renders a faithful width without replicating the home engine's brush dynamics).
  - `pressure[]` — `f32` 0–1, and `tMillis[]` — `u16` deltas (raw inputs, so the *home* platform can
    re-synthesize with native dynamics). Tilt/orientation arrays are flag-gated, written only when the
    device provided them.

**Fidelity contract (pin in tests):** cross-rendered ink (an iOS-authored stroke shown on Android and
vice versa) is **faithful, not pixel-identical**. Highlighter differs most between engines — validate it
first.

The `InkStroke` binary codec lives in Domain (Foundation-only) so it compiles for both toolchains and is
the single source of truth for the byte layout.

## 5. Shared anchoring core

### 5.1 Neutralize `AnnotationAnchoring` (Reader package)

Today `AnnotationAnchoring.swift` and `PDFAnnotationAnchoring.swift` live in the Reader feature and are
entangled with PencilKit (`[PKStroke]` I/O, `PKDrawing.transform(using:)` baking). The core math —
`anchorPoint`, `normalizeTransform`, `displayTransform`, `partitionByPage` — already touches only
`LayoutDocument`, `MusicalAnchor`, and affine transforms. Refactor to:

- **`capture(strokes: [InkStroke], resolveAnchor) -> [DrawingAnchor]`** — pick the representative point
  per stroke (bounding-box center, from the shared `AnnotationAnchorPolicy` — also neutralized so the
  heuristic can't drift), resolve it to a `MusicalAnchor`, bake geometry into anchor-relative sp
  (translate + uniform scale), encode `InkStroke`.
- **`display(drawings: [DrawingAnchor], referencePoint) -> [StrokeTransform]`** — for each drawing,
  resolve its anchor's reference point and return the **per-stroke transform as 3 floats `(sp, Px, Py)`**
  (uniform scale + translate), *not* transformed geometry. This keeps the JNI display call ~12 bytes per
  stroke and lets Android apply the transform with `Canvas.concat` over cached geometry — mechanical
  rendering, not re-implemented logic.
- **`partitionByPage(...)`** for paged modes — assign each stroke to a page band, keeping unresolved
  anchors off-page rather than dropping them (prevents ink loss). Shared.

iOS keeps thin `PKStroke ↔ InkStroke` adapters in the Reader feature; the neutral core is what both
platforms call.

**Placement note:** the neutral core stays in the **Reader package** (not moved to Domain). Domain
currently depends only on `SheetMusicCore`, not `SheetMusicLayout` (where `LayoutDocument` lives), and
the anchoring *algorithm* is Reader-specific. The data model (`MusicalAnchor`, `InkStroke`) is Domain;
the algorithm is Reader. `FolinoReaderJNI` is in the Reader package, so it can call the core directly.

### 5.2 Reaching `LayoutDocument` on Android — ssm anchor primitives

On Android, `LayoutDocument` is cached inside ssm's `SheetMusicAndroidJNI` `.so`
(`LayoutDocumentCache.value(for: scoreHandle)`), a different `.so` from `FolinoReaderJNI`. Add two
Folino-agnostic JNI entry points to ssm, mirroring `nativeNearestCursor`:

- `nativeResolveAnchor(scoreHandle, xMm, yMm, hiddenStavesBytes) -> ResolvedAnchor bytes` (empty on
  miss).
- `nativeAnchorReferencePoint(scoreHandle, anchorsBytes) -> points bytes` (batched: all of a layer's
  anchors in one call, for the hot display path).

**Seam:** Kotlin plumbs bytes between the two native calls — it calls ssm for anchor resolution and
Folino's `FolinoReaderJNI` for the affine bake/transform. Kotlin does **no math** (pure byte passing
between native calls); all anchoring logic stays in shared Swift. Whether the affine bake ultimately
co-locates into ssm (as a generic geometry primitive over `ResolvedAnchor`) is an early implementation
choice — both variants keep the logic in shared Swift; settle it in the first spike (§10).

## 6. Android rendering & input

### 6.1 Ink stack — wet/dry split (androidx.ink)

- **Wet (in-progress) = `androidx.ink` 1.0.0** (Apache-2.0; new Gradle dependency). Use the
  `ink-authoring-compose` `InProgressStrokes` composable (fall back to `AndroidView(InProgressStrokesView)`
  if an unexposed API is needed) for front-buffered, motion-predicted, low-latency capture. Pin
  **versioned stock brushes (`StockBrushes.*V1`)**, never `*Latest`, to avoid OS-upgrade brush drift.
- **Capture in document-mm coordinates.** Pass `motionEventToWorldTransform` (the inverse of
  `pxPerMM × scrollOffset`) to `startStroke` so recorded input is zoom-invariant; specify brush
  `size`/`epsilon` in document units.
- **Dry (committed) = own `CanvasStrokeRenderer`** in a **sibling overlay composable** over `ScorePage`,
  exactly where the playback cursor and loop-highlight overlays already live, working in absolute
  document coordinates. Because Android **re-renders vectors at `pxPerMM × scale`** (zoom is a
  re-render, not a raster magnification — verified in `ReaderScreen.kt` / `PagedScore.kt`), committed
  ink stays crisp at 8× with **no raster `StaticInkLayer` equivalent needed** (unlike iOS).
- **Commit handoff:** on `onStrokesFinished`, extract the `StrokeInputBatch` inputs → capture (§5) →
  add to the dry overlay → call `removeFinishedStrokes` **in the same frame** (avoids ghost/flicker).
  Never persist androidx.ink's own serialized format — only the neutral `InkStroke` extracted from
  `Stroke.inputs`; rebuild `Stroke(brush, inputs)` on load.

### 6.2 Gotchas to design around (the 16k-Metal analogs)

- **No offscreen compositing** on the ink or document layers (`CompositingStrategy.Offscreen`,
  `alpha < 1`, `renderEffect`) — HWUI offscreen layers hit the max-texture cap (device-dependent
  4096–16384 px); a vertical document at 8× far exceeds it. Apply stroke alpha per-paint.
- **float32 precision:** deep in a long document at 8×, absolute px coordinates quantize visibly. Build
  the dry-draw matrix in **viewport-local space** (subtract scroll offset first), as the score canvas
  already does.
- If raster caching of ink is ever needed for perf, tile at ≤4096 px, viewport-scoped.

### 6.3 Three-mode integration

- **Vertical / Horizontal:** dry overlay directly above the score canvas. On reflow (a
  `viewportWidthMm` / `layoutOptions` change re-runs `nativeComputeLayout`), re-fetch per-stroke
  transforms via the display JNI and re-place cached geometry. **Do not re-project while actively
  drawing** (the Android analog of iOS's `if !isAnnotating` gate).
- **Paged:** place the dry overlay **inside the `HorizontalPager` page content** so page-turn slide/zoom
  carries it for free. Use `partitionByPage` (shared core) to assign strokes to page bands.

### 6.4 Input model (finger + stylus)

In annotation mode: **one finger or stylus draws; two fingers navigate** (route the two-pointer gesture
to the existing pinch/pan handlers). Stylus always draws. The app decides which pointers call
`startStroke`. (iOS uses Pencil-only-draws on iPad; Android differs deliberately per D4 so finger-only
devices can draw.)

## 7. Tool palette & Reader UX (Android idiom)

- **Toolset (D3):** pen, highlighter, eraser, color palette, stroke width, undo/redo. Eraser is
  **whole-stroke** in v1 (tap/drag a stroke to delete). Undo/redo backed by a per-session stroke stack
  on the view model.
- **Placement (Android idiom):** a Material **bottom toolbar** shown only while annotation mode is
  active. Entry point: a pencil/edit action in the Reader top bar toggles the mode. Exact placement,
  icons, and spacing are UI tuning to refine by eye later (and per project convention are **not**
  auto-committed).
- **Mode toggle:** a `MutableStateFlow<Boolean>` on `ReaderViewModel` (the cheapest pattern, same as
  `layoutOptions`) gates the overlay, the toolbar, and input routing. **Disabled during playback**
  (parity with iOS). While active, the rest of the reader chrome dims/hides (parity with iOS hiding its
  top overlay).
- **Analytics:** mirror iOS (`annotation_started` / `annotation_ended` with a stroke count) via the
  existing Android analytics path.

## 8. Android persistence

Follow the existing per-score `reader_preferences` pattern in `RoomLibraryStore.kt`:

- **New Room entity** `annotation_layers(score_id PK, payload BLOB, updated_at)` — mirrors the iOS GRDB
  table 1:1. `payload` = JSON `{ drawings, textBoxes }` with base64 `InkStroke` blobs inside.
- **Exposed to shared Swift** as a `@WireletProvided AnnotationStore` implemented by `RoomLibraryStore`
  (the same mechanism as `ReaderPreferencesStore`), so the store is Kotlin/Room but its **caller is
  shared Swift**.
- **Save policy is shared Swift:** layer assembly, the 0.5 s debounced save, and empty-layer → delete
  are implemented once in shared Swift (mirroring iOS `ReaderViewModel+AnnotationPersistence.swift`),
  reached from Kotlin via a `@WireletObservable` annotation bridge modeled on `ReaderPreferencesBridge.swift`.
  Kotlin only supplies UI events and the Room backend.

## 9. iOS migration (to the neutral format)

Per D5/D6, iOS converges on the neutral format **now**, while the install base is smallest:

- **Codec:** implement `PKDrawing ↔ InkStroke` on iOS (encoder + decoder), validated by a round-trip
  test (§10) *before* it is used for writing.
- **Read-both, permanently:** retain the legacy `PKDrawing` decoder forever, so any record still in the
  old format is always readable.
- **One-time migration:** on upgrade, convert all existing `annotation_layers` from PKDrawing → neutral
  using the validated codec, keeping the original blob as a transitional backup until the migration is
  confirmed. Safe at ~dozens-of-users scale.
- **Write-neutral** thereafter. iOS PencilKit drawing UI is otherwise unchanged — it feeds the neutral
  codec at the persistence seam instead of writing a PKDrawing archive.
- **Cloud safety (insurance):** the CloudKit sync layer should **preserve payloads it cannot decode**
  (round-trip unknown bytes untouched, never drop/clobber strokes). Combined with read-both and the tiny
  base, this removes the theoretical cross-version clobber. The multi-device mixed-version window is
  negligible at current scale.

**Why now:** format migrations are cheapest when the install base is smallest; a 2-day-old feature with
~dozens DAU is the ideal window. Waiting only accumulates PKDrawing data and makes a later migration
riskier. Doing it now also **production-validates the neutral format on iOS immediately** (real users'
ink round-tripping through neutral) — stronger evidence than unit tests that the format is
share-ready for the future export/import feature.

## 10. Testing

- **Shared Swift round-trip test** (in the neutralized anchoring core): `capture → display` at the same
  layout must be exact (the file's own documented invariant). Run on **both** the Apple and Android
  toolchains.
- **iOS codec round-trip test:** `PKDrawing → InkStroke → PKDrawing` preserves pen vs highlighter,
  color, opacity, width profile, and pressure within the stated fidelity contract. Validate
  **highlighter first** (worst-case divergence).
- **Android instrumented tests:** draw → commit → reflow → ink follows the correct musical positions;
  page-turn carries paged ink; zoom keeps ink crisp. Android ink **renders in the emulator** (Compose
  Canvas), so emulator screenshot verification works — unlike iOS, where PencilKit ink does not
  composite in the simulator.
- **Device matrix:** test wet capture early on an **S-Pen Samsung** and the **Pixel Tablet**
  (front-buffer rendering has device-specific quirks).

## 11. Build & cross-repo sequencing

- **ssm lands first.** Add the anchor-primitive JNI to swift-sheet-music, merge to ssm main, then re-pin
  Folino (all five `Package.swift` + `project.yml`). Per `feedback_ssm_side_land_independently`, do not
  create version skew.
- **Reader `.so`:** `Scripts/android-build-reader-libs.sh` rebuilds `FolinoReaderJNI` with the new
  capture/display symbols (+ jextract Java).
- **Wirelet codegen:** the Library module's annotation bridge/store generates via the existing wirelet
  Gradle tasks; rebuild the Library `.so`.
- **New dependency:** `androidx.ink` (Apache-2.0) added to `Android/FolinoReaderAndroid/build.gradle.kts`.
- **Ordering reminder** (fresh worktree): run wirelet codegen → (re)build `.so`s → `assembleDebug`;
  building `.so`s first yields libraries without `JNI_OnLoad` that crash at launch.

## 12. Risks & early spikes

1. **ssm anchor-primitive seam** (highest) — add `nativeResolveAnchor` / `nativeAnchorReferencePoint`,
   and settle whether the affine bake co-locates in ssm or stays in `FolinoReaderJNI` with Kotlin byte
   plumbing. First spike; both keep logic in shared Swift.
2. **androidx.ink device quirks** — front-buffer rendering; validate on S-Pen + Pixel Tablet early. The
   wet/dry split is the insurance: if a device-class blocker appears, wet capture falls back to plain
   `pointerInput` without touching anchoring or persistence.
3. **Highlighter round-trip fidelity** — prototype the highlighter neutral round-trip first; pen strokes
   are the easy case.
4. **Deep-zoom f32 / texture limits** — viewport-local dry matrix; no offscreen compositing.

## 13. Out of scope / future

- "Share an annotated score" export/import (the feature this format work enables).
- Android PDF annotation (blocked on Android PDF reader).
- iOS↔Android live cloud sync.
- Text boxes authoring on Android.
- Range-anchoring / stretch marks (`project_annotation_range_anchoring`).

## 14. Open implementation choices (for the plan phase)

- Exact `InkStroke` binary layout (endianness, flag bit positions) — finalize in the plan.
- ssm bake co-location vs Kotlin plumbing (spike 1 outcome).
- Whether the iOS one-time migration runs as a GRDB migration step or a lazy-on-first-load pass with a
  completion flag — both keep the legacy decoder; pick in the plan.

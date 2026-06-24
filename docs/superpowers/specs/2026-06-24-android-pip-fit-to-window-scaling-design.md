# Android PiP fit-to-window scaling (iOS parity) — design

**Status:** Draft for review
**Date:** 2026-06-24
**Feature package:** `Android/FolinoReaderAndroid` (Android) + `Packages/Features/Reader` (iOS) + `Packages/Domain` (shared)
**Touches:** Android (`ReaderPipContent`, `HorizontalScore` in `ReaderScreen.kt`, `PipAspect.kt`, `ReaderScreen.kt` aspect publish); Domain (new `PiPLayout.swift`); iOS (`ScorePiPFrameRenderer`); `FolinoReaderJNI` (new symbol)

## Goal

Make the Android Picture-in-Picture score render **scaled to the current PiP window size** so the
**full system height is always visible at both PiP size stages** — matching iOS. This fixes two
overflow bugs the user observed:

- **Small stage clips:** the score is sized correctly only for the *large* PiP stage; at the small
  stage it overflows (and PiP has no scroll gesture, so the cut-off region is unreachable).
- **Tall systems overflow even the large stage:** when the system is taller than a threshold, the
  score does not fit even in the large window.

Target behavior (iOS parity): small window → the whole score scales down uniformly (finer but the
entire system height stays visible); large window → fits exactly; tall systems → the score shrinks
so the full height still fits.

## Background — root cause

Android PiP keeps the Activity alive and renders the **live Compose UI** into the actual PiP window
surface. `ReaderPipContent` → `HorizontalScore` renders at a **window-size-independent fixed
density**:

```
fitPxPerMM = fixedPxPerMm(density.density)        // ReaderScreen.kt:1292
contentHeightPx = page.heightMM * fitPxPerMM      // constant, regardless of window size
```

So the on-screen system height is a constant. It can match exactly **one** window size; every other
size over- or under-fills. The large stage roughly matches (the window aspect was tuned for it); the
small stage and tall systems do not. The window **aspect** is published separately
(`pipAspectForSystemHeight`, `PipAspect.kt`) on an A4-width (210 mm) basis that no longer matches the
fixed-density render, compounding the mismatch.

iOS does not have this problem because it renders differently (`ScorePiPFrameRenderer`): the score is
drawn **once** into a fixed-size `CVPixelBuffer` at a scale that fits the system into the buffer
(`scoreScale = min(pipStaffShrinkFactor, usableHeight / systemHeight)`), and **AVKit scales that
buffer to whatever PiP window size**. "Full system always visible" is free — it is a property of the
OS scaling a fixed-aspect buffer. Android has no AVKit-style buffer-scaling pipeline (it renders live
composables), so the equivalent must be achieved by **making the render density depend on the window
size** — i.e. fit-to-height.

## Key insight

This is the Android analogue of iOS's `scoreScale`: instead of a fixed density, derive the density
from the **measured PiP window height** so the system fills it. The window size is already observed —
`HorizontalScore` measures `viewportSize` via `onSizeChanged` (`ReaderScreen.kt:1368`), and a PiP
resize (double-tap large/small, or pinch) changes the window bounds → re-layout → `viewportSize`
updates → density recomputes. No new size-observation machinery is needed.

Most of the surrounding machinery is reused unchanged: the horizontal cursor auto-scroll
(`nativeScrollOffsetPinningSystemTop` / `nativeHorizontalMeasureScrollOffset`) keeps the playing
measure in view on the X axis exactly as today. Because the system now always fits vertically,
`needsVScroll` is constant-false on the PiP path (the vertical-scroll branch becomes dead there).

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Overall approach | **Fit-to-height live render** (Approach A). Reject off-screen-buffer mirroring (no AVKit equivalent; reimplements fit-to-height the long way) and fixed-density-tuned-to-large-stage (cannot satisfy both stages). |
| Scope of "match iOS" | Match iOS behavior **for every item Android can also configure.** The cleanly shared, configurable item is the **window aspect ratio** → share its heuristic. |
| Shared-logic depth | **(1) Single source.** Lift the window-aspect heuristic into `Domain` as a pure function; **both** iOS and Android call it (iOS via direct call, Android via `FolinoReaderJNI`), per the established `ScrollFollow.swift` parity pattern. iOS's inline aspect constants are replaced by the shared call. |
| Aspect heuristic | Adopt iOS's **staff-count** basis (`aspectNumerator / staffCount`), replacing Android's A4-width/height basis. |
| Aspect clamp range | `minAspect = 1.0` shared (don't make the PiP window taller than square; let fit-to-height shrink the score instead — iOS behavior). `maxAspect` diverges by OS: iOS `6.0`, Android `2.34` (Android rejects aspect outside ~[1/2.39, 2.39]; this is an OS hard limit, documented as an intentional divergence, not a choice). |
| Breathing room | Android leaves vertical margin so the system occupies ~the same fraction of the window height as on iOS. Tuned empirically against an iOS side-by-side (not a shared function — it is a rendering-model detail, not a configurable item). |
| Full-screen Reader | **Untouched.** Only the PiP render path changes; the full-screen horizontal/vertical surfaces keep fixed-density rendering. |

## Components

### 1. Android — fit-to-height PiP render (`HorizontalScore` PiP path)

`ReaderPipContent` already forces `HorizontalScore` with `mode = .HORIZONTAL`. Add a PiP flag (or a
dedicated density parameter) so that, **in PiP only**, the density is computed from the measured
window height instead of `fixedPxPerMm`:

```
pipPxPerMM = (viewportSize.height - 2 * verticalPadPx) / page.heightMM
```

- Recomputed on every `viewportSize` change → tracks PiP resize automatically.
- The system always fits vertically ⇒ `needsVScroll == false` on this path; center vertically (the
  existing short-row centering branch already handles this).
- Horizontal cursor auto-scroll, pinch (if desired in PiP — likely disabled), tap-to-seek, and the
  cursor/loop/AB overlays continue to use `pipPxPerMM` as their `pxPerMM`.
- The full-screen Reader keeps `fixedPxPerMm`. The branch is gated on the PiP flag so non-PiP
  rendering is byte-for-byte unchanged.

### 2. Domain — shared window-aspect heuristic (`Packages/Domain/Sources/Domain/PiPLayout.swift`, new)

A pure function mirroring `ScrollFollow.swift`'s style (documented, parity note, Foundation-only):

```swift
/// PiP window aspect ratio (width / height) from the rendered system's staff count. Fewer staves →
/// flatter (wider) window; more staves → squarer, bottoming out at `minAspect` (where the renderer
/// shrinks the score to fit instead of growing the window taller). Shared by iOS and Android
/// (parity: one implementation; iOS calls directly, Android via FolinoReaderJNI).
public func pipWindowAspect(
    staffCount: Int,
    aspectNumerator: Double,   // 6.0
    minAspect: Double,         // 1.0 (both platforms)
    maxAspect: Double,         // iOS 6.0, Android 2.34 (OS limit)
) -> Double
```

Covered by Domain unit tests (Swift Testing), alongside `ScrollFollowTests`.

### 3. `FolinoReaderJNI` — bridge `pipWindowAspect` to Android

Add a symbol in `Packages/Features/Reader/Sources/FolinoReaderJNI/JNISymbols.swift` that wraps
`Domain.pipWindowAspect` (mirrors how `n` / `scrollOffsetPinningSystemTop` is exposed), surfaced to
Kotlin as e.g. `nativePipWindowAspect(staffCount, aspectNumerator, minAspect, maxAspect)`. Requires a
`.so` rebuild for the new symbol (`android-build-library-libs.sh` path; see Risks).

### 4. Android — replace `pipAspectForSystemHeight` with the shared call

In `ReaderScreen.kt:307–311`, publish the aspect from the staff-count heuristic via the new JNI
symbol instead of `pipAspectForSystemHeight(page.heightMM, A4_WIDTH_MM)`:

```
ReaderPipController.setContentAspect(
    FolinoReaderJNI.nativePipWindowAspect(staffCount, 6.0, 1.0, PIP_MAX_ASPECT /* 2.34 */),
)
```

Staff count sourcing (iOS reads `firstSystem.staffOrigins.count` = rendered, post-hide staff count):
the Android Reader already exposes the parts/staves structure (`readerVm.parts` /
`nativePartsStaves`) and the hidden-staff set. The plan picks either (a) `parts` minus hidden staves,
or (b) a small `nativeSystemStaffCount(handle, options)` JNI accessor that returns the laid-out
system's staff-origin count (most faithful to iOS). `pipAspectForSystemHeight` is removed;
`pipAspectClamped` / `PIP_MAX_ASPECT` stay (still used by `buildPipParams`).

### 5. iOS — adopt the shared aspect function

In `ScorePiPFrameRenderer.init`, replace the inline
`max(minAspect, min(maxAspect, aspectNumerator / staffCount))` with
`pipWindowAspect(staffCount:aspectNumerator:minAspect:maxAspect:)`, passing the existing constants
(`aspectNumerator = 6`, `minAspect = 1.0`, `maxAspect = 6.0`). Behavior is identical by construction;
`ScorePiPFrameRendererTests` continues to pass (and gains coverage of the shared function via Domain
tests).

### 6. Breathing-room tuning (Android)

Pick `verticalPadPx` (and, if needed, a small shrink factor) so the staff's on-screen size in PiP
reads at parity with iOS. Verified visually side-by-side, not asserted in tests.

## Testing

- **Domain:** `pipWindowAspect` unit tests — staff-count sweep, both clamp ends, the iOS-vs-Android
  `maxAspect` divergence (e.g. 1-staff: iOS 6.0, Android 2.34; 3-staff: both 2.0; 6-staff: both 1.0).
- **iOS:** `ScorePiPFrameRendererTests` unchanged-green after routing through the shared function.
- **Android:** unit test for the fit-to-height density formula (pure arithmetic; runnable in the
  Reader package test target). `xcodebuild test -scheme <Pkg> -destination 'platform=iOS Simulator,
  name=iPhone 17 Pro Max'` for the Domain/JNI Swift side.
- **Manual (Android):** user verifies in PiP — small stage shows full height (finer), large stage
  fits, tall multi-staff score fits, resize (double-tap) rescales smoothly. Per the Android workflow,
  Claude does `installDebug` + launch; the user performs the PiP gestures.

## Non-goals

- **No change to the full-screen Reader** (horizontal/vertical/page) — fixed-density rendering stays.
- **No new PiP controls / transport / gesture behavior** — only the score's scale and the window
  aspect change.
- **No attempt to lock the PiP size stage** — Android exposes no API for it (established earlier in
  this thread); fit-to-height makes both stages correct regardless.
- **No change to iOS PiP behavior** — only an internal refactor to call the shared aspect function.

## Risks / notes

- **`.so` rebuild for the new JNI symbol.** Adding `nativePipWindowAspect` (and possibly
  `nativeSystemStaffCount`) means the `FolinoReaderJNI` `.so` must be rebuilt; see
  `reference_android_fresh_worktree_app_build` / `project_library_android_native_drift` for the
  rebuild path and native-drift pitfalls. If staff count is sourced from existing `parts` instead of
  a new accessor, only the one aspect symbol is new.
- **Non-seamless resize.** `setSeamlessResizeEnabled(false)` (`ReaderPipIntegration.kt:60`) stays — a
  PiP resize crossfades to the re-rendered size, matching the iOS/AVKit feel.
- **Reverses a prior decision.** Memory note `reference_android_layout_fixed_density` recorded "PiP は
  据え置き" (PiP not reflowed). This spec intentionally supersedes that for the PiP scale axis; the note
  should be updated once shipped.

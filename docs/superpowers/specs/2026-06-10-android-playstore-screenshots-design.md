# Android Play Store Screenshot Harness — Design

**Date:** 2026-06-10
**Status:** Approved (brainstorming complete)
**Scope:** Automated generation of Google Play store screenshots for the Folino Android app, modeled on the existing VocalTuner pipeline.

## Goal

Produce localized, device-framed marketing screenshots for the Play Console with a single Gradle command, reaching specific in-app states deterministically. The pipeline mirrors VocalTuner's **scene → marketing frame → fastlane supply** structure, adapted to Folino's constraints.

## Key constraint that shapes the design

VocalTuner renders Compose to PNG on the **host JVM** via Roborazzi + Robolectric (no emulator). Folino's Reader renders sheet music through **native JNI** (`SheetMusicJNI`, `ScoreHandle.load`, the sheet-music engine `.so` libraries), which cannot load on the host JVM. Five of six requested screenshots show a rendered score.

**Therefore capture runs as an instrumented test on an emulator/device**, where the native libraries are available — but the *structure* (scenes, marketing frames, fastlane output tree) stays faithful to VocalTuner.

Each scene's Compose content is composed into a **fixed-dp, fixed-density marketing frame** and captured at the **node** level (not the device window), so a single AVD produces both phone and tablet outputs regardless of the emulator's real resolution.

## Scope

### In scope (this pass — 4 screenshots)

1. **Reader + cursor** — score open, cursor positioned ~middle of measure 1.
2. **Display inspector + hidden staves** — display inspector open, staves 2/3/4 hidden.
3. **Library top** — Library home with mock scores (see Mock data).
4. **PiP-style on home screen** — a faux launcher background with a floating PiP-style Reader card showing **only** staves 2/3/4 visible.

(Numbered 1/3/5/6 in the user's original request; renumbered 1–4 here as the in-scope set.)

### Deferred (out of scope — depend on an unbuilt feature)

The two repeat-dependent screenshots are deferred because **Android has no repeat feature yet**:

- **Whole-piece repeat (`loopAll`)** — playback inspector open, single-song repeat enabled.
- **AB-section repeat** — region set to measures 5–7.

iOS defines `RepeatMode { off, loopAll, abLoop }` (`Packages/Domain/.../RepeatMode.swift`) and `ABRepeatRange`/`ChordPath` (`Packages/Domain/.../PlaybackPreferences.swift`), with a 3-state inspector button and on-score A/B markers. The Android Reader exposes only a **read-only** `ReaderAudioViewModel.loopRange: StateFlow<LoopRange?>` that **no composable consumes** — there is no enum, no setter, and no UI. Capturing these states requires building the feature first.

**Forward-compat hook:** the scene list reserves order slots so the two scenes can be inserted later without renumbering existing outputs (see Scene ordering).

## Architecture

New instrumented source set under the app module, plus Gradle/fastlane wiring.

```
Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/
├── ScreenshotTest.kt            # @Test captureAll(): device × locale × scene loop
├── ScreenshotConfig.kt          # Device {PHONE, TABLET}, ScreenshotLocale {JA, EN}
├── frame/                       # ported/adapted from VocalTuner
│   ├── ScreenshotLayout.kt      # phone()/tablet(): frame slot %, design density, output px
│   ├── ScreenshotFrame.kt       # device frame + title/subtitle caption + gradient background
│   └── ScreenshotAnnotation.kt  # optional positioned captions/arrows (fractional coords)
├── fixtures/
│   ├── MarketingStrings.kt      # locale → {title, subtitle} placeholder copy, per scene
│   ├── MockScores.kt            # the three mock library rows + their score ids
│   └── ScoreRendering.kt        # asset mscz → ScoreHandle.load → layout → ScorePage helper
└── scenes/
    ├── Scene.kt                 # Scene(order, content(layout, localeTag)); ordered Scenes.all
    ├── ReaderCursorScene.kt     # #1
    ├── DisplayHiddenScene.kt    # #2 (display inspector + hidden staves)
    ├── LibraryScene.kt          # #3 (library top)
    └── PipScene.kt              # #4 (faux home + PiP card)

Android/app/src/androidTest/assets/Now_is_the_time.mscz   # copied from ~/Desktop, committed
```

Build/distribution wiring:

- `Android/app/build.gradle.kts` — apply the Roborazzi Gradle plugin; declare Roborazzi + (instrumented) Compose-UI-test dependencies on `androidTestImplementation`; register a `collectScreenshots` task.
- `Android/fastlane/` — `Appfile` (package + service-account placeholder), `Fastfile` (`upload_screenshots` lane, images-only), `README.md`.

### Capture mechanism

- Roborazzi in **instrumented (connected) mode**: `captureRoboImage(filePath = …) { … }` inside an `androidTest` running on the emulator. The native engine loads normally.
- Each scene is wrapped in its device's `ScreenshotFrame`, which fixes the composable's pixel size via an explicit `Box` size + a `CompositionLocalProvider(LocalDensity)` override. The capture targets that fixed-size node, so phone vs. tablet output dimensions are independent of the AVD's real screen. One AVD suffices.
- Loop: `for device in {PHONE, TABLET} → for locale in {JA, EN} → set locale qualifier → for scene in Scenes.all → captureRoboImage(<device>/<playLocale>/<NN>.png)`.

### Marketing frame

Ported from VocalTuner `frame/`:

- `ScreenshotLayout.phone()` / `.tablet()` — title top %, subtitle %, frame slot %, rounded corners, status-bar height, **design density** and **output pixel size** (phone ≈ 1080×1920, tablet ≈ 1600×2560 — exact values matched to Play Console requirements during implementation).
- `ScreenshotFrame` — dark vertical-gradient background, top title + subtitle (from `MarketingStrings`), device frame with rounded corners around the captured app content.
- App content is composed at a realistic device dp width and scaled into the frame slot via the density override (Compose analog of "render full-size, scale the image").

### Output → fastlane

- Raw capture: `app/build/outputs/roborazzi/<deviceAlias>/<playLocale>/<NN>.png`.
- `collectScreenshots` (depends on the Roborazzi record task) copies into the supply tree:
  `Android/fastlane/metadata/android/<playLocale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png`.
- Locales: `ja-JP`, `en-US`. Device → dir: PHONE → `phoneScreenshots`, TABLET → `tenInchScreenshots`.
- Matrix: 4 scenes × 2 locales × 2 devices = **16 PNGs**.
- Upload to Play Console is a **separate, manual** `fastlane supply` step (not run by the harness); credentials are placeholders in the repo.

## Scene state construction (Compose synthesis)

All scenes compose **real production composables** with injected state where possible; only the faux launcher background (scene #4) is bespoke.

### #1 Reader + cursor
- `ScoreRendering` loads `assets/Now_is_the_time.mscz` → `ScoreHandle.load(bytes)` → native layout → `ScorePage`.
- `LayoutOptions.DEFAULT`.
- Cursor: inject a cursor value corresponding to **measure 0 (first measure), mid-measure** so the Reader's cursor overlay renders there. Exact cursor construction (nearest-cursor at the measure's mid tick/x) resolved during planning against `ReaderAudioViewModel`/`nearestCursor` APIs.

### #2 Display inspector + hidden staves
- Background: Reader content with `LayoutOptions.hiddenStaves = { StaffAddress for the 2nd, 3rd, 4th staves }` (encoded as `"<partIndex>:<staffIndexInPart>"`, e.g. `0:1, 0:2, 0:3` — actual part/staff addresses derived from the loaded score's `parts`).
- Foreground: the real `DisplayInspectorSheet` composable rendered in its expanded/open state, its Parts rows reflecting staves 2/3/4 as `VisibilityOff`.

### #3 Library top
- Seed Room (`folino-library.db`) with three mock rows derived from `Now_is_the_time`:
  - `Now is the time` (original metadata),
  - `アタタメマスカ` — **composer cleared (empty)**,
  - `Looks_Good_To_Me`.
- For each, copy the asset into `filesDir/Scores/<id>.mscz` and upsert a `ScoreRecordEntity`/`ScoreRecordWire` with a fresh UUID + matching `localFileName`.
- Render the real `LibraryScreen` bound to a store backed by the seeded DB.

### #4 PiP-style on home screen
- Bespoke faux-launcher Compose background (wallpaper-ish gradient + a simple app-icon grid + status/nav bar hints) — no system PiP (impossible from a Compose capture).
- Overlaid rounded floating card containing Reader content with **only staves 2/3/4 visible** (hide all other staves via `hiddenStaves`), sized to a PiP-like aspect ratio.

## Mock data

- Source: `~/Desktop/Now_is_the_time.mscz` (108 KB), copied to `Android/app/src/androidTest/assets/Now_is_the_time.mscz` and committed so the harness is self-contained.
- `MockScores` defines the three rows and their deterministic ids (fixed UUIDs so outputs are stable across runs).

## Localization

- `MarketingStrings` holds `{ title, subtitle }` per (scene, locale) for `ja` and `en`, with **placeholder copy** flagged for later replacement.
- App content localization follows the active locale qualifier set per loop iteration.

## Testing / verification

- The harness *is* an instrumented test; "passing" = it renders all 16 PNGs without crashing and each file is non-empty with the expected pixel dimensions.
- Manual visual check on the generated PNGs (cursor placement, hidden/visible staves correct, mock library rows present with composer blank on `アタタメマスカ`, PiP card shows only staves 2/3/4).
- No new production-code unit tests are required; production composables are reused, not modified (except any minimal hooks needed to inject cursor/inspector-open state, which—if added—get a focused test).

## Run command

```
# AVD booted beforehand
./gradlew :app:collectScreenshots
# → 16 PNGs under Android/fastlane/metadata/android/<locale>/images/<...>/NN.png
```

Upload (manual, separate): `cd Android/fastlane && bundle exec fastlane android upload_screenshots`.

## Risks / open implementation questions (resolved during planning)

1. **Roborazzi instrumented + fixed-size node capture** — confirm `captureRoboImage` captures a sized node independent of window size on a connected device; fall back to Compose `captureToImage()` on a sized test node if needed.
2. **Cursor injection** — whether the Reader exposes enough to set a static cursor without playback; may need a small testable seam in `ReaderScreen`/`ReaderAudioViewModel`.
3. **Inspector "open" composition** — render `DisplayInspectorSheet` content directly (bypassing `ModalBottomSheet` scrim/animation) for a clean static frame.
4. **Native libs in androidTest** — ensure the app's `jniLibs` (engine + Folino JNI `.so`) are packaged into the test APK / available to the instrumented process.
5. **Exact output dimensions** — match Play Console phone & 10" tablet requirements.
```

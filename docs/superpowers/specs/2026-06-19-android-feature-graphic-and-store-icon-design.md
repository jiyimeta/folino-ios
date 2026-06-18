# Android Play Store feature graphic + store icon — design

- Date: 2026-06-19
- Status: design (approved to write plan)
- Scope: Android (`Android/`), Play Store listing assets only. No app feature / runtime behavior change.
- Reference: ports VocalTuner's 2026-06-18 feature-graphic auto-generation + full-bleed 512 store icon
  work (commits `a542330`, `3311348`, `922b162`, `36f2be7`, `64e8c24`, `8cd0532`, `783edce`, `f810450`,
  `649f0d8`) onto Folino's existing instrumented screenshot harness.

## Goal

Auto-generate two Play Store listing assets Folino is currently missing, the same host-reproducible
way the store screenshots are already generated, so they never have to be hand-authored and stay in
sync with the real app + brand:

1. A **feature graphic** (1024×500 banner) — one per shipped locale — composed of the folino wordmark
   logo + a localized tagline on the left, and the real Reader sheet-music screen in a device frame on
   the right, over the brand white→`#CEE1FF` gradient.
2. A **full-bleed 512×512 store icon** — the folino adaptive-icon artwork rendered edge-to-edge — fanned
   out to every locale's `images/icon.png`.

Plus one related app-icon improvement requested alongside:

3. A **themed-icon (`<monochrome>`) layer** for the Android adaptive launcher icon, which Folino's icon
   currently lacks (no Android-13+ themed-icon support).

## Why this shape

- Folino's screenshot harness is **instrumented** (connected device), not host-side Robolectric like
  VocalTuner, because the Reader renders sheet music via native JNI `.so` libraries that cannot load on
  the host JVM (documented in `CaptureHarness.kt` and `app/build.gradle.kts`). The feature graphic shows
  the real Reader screen on the right, so it **must** be captured the same instrumented way. We therefore
  reuse `captureFixedSize` / the device frame / a Reader scene rather than porting VocalTuner's host-side
  Robolectric path.
- The brand is **light** (white→`#CEE1FF` gradient, slate-navy `#1E2438` ink), the opposite of
  VocalTuner's dark banner. The feature graphic uses Folino's existing `ScreenshotLayout.iconGradient`
  and `captionInk`, so the banner reads as folino and matches the store screenshots.
- Folino's app icon **is a wordmark** ("folino": f-as-clef swash, first-o-as-notehead, Edwin italic
  serif, plus a curved 5-line staff). The icon foreground art therefore doubles as the brand logo. The
  banner's left column shows that wordmark art directly (no separate "app name" text, and no rounded
  app-icon badge — a gradient squircle on the same gradient would read as low-contrast).

## Non-goals

- No change to the icon **artwork** itself (no redesign of the folino mark). We only derive new
  store-listing renditions (full-bleed 512, monochrome) from the existing art + gradient.
- No change to the existing 6 scenes × 5 locales × 2 devices screenshots' appearance. The `DeviceFrame`
  extraction must be **pixel-preserving** for them.
- No new third-party dependency, no new Gradle plugin.
- Not localizing the brand name (the wordmark is the same lowercase "folino" in every locale). Only the
  tagline is localized.
- iOS gets no feature graphic (the App Store has no such asset). This is Android-only.

## Decisions (locked)

| Decision | Choice | Rationale |
| --- | --- | --- |
| Feature-graphic composition | Left: folino wordmark logo + localized tagline. Right: real Reader screen in a device frame. | Mirrors VocalTuner's text-left / app-right layout, adapted to folino's light brand + wordmark icon. (User-selected.) |
| Background | `ScreenshotLayout.iconGradient` (white→`#CEE1FF`) | Brand consistency with the icon + the store screenshots. |
| Text ink | `captionInk` `#1E2438` (tagline) | Readable on the light gradient; same ink as the screenshot captions. |
| Capture mechanism | Instrumented `captureFixedSize` (connected device) | The Reader needs native JNI; host-side Robolectric can't render it. |
| Device-frame reuse | Extract `DeviceFrame` from `ScreenshotFrame`; both delegate to it | Avoids duplicating the density-lowering trick; mirrors VocalTuner 922b162. Must be pixel-preserving. |
| Store icon (512) | Render in-pipeline from `R.mipmap.ic_launcher_foreground` + `iconGradient`, full-bleed, sharp corners | Reproducible, stays in sync with the brand, gitignored like screenshots. Google applies the rounded mask. (vs. committing a static PNG.) |
| Themed icon | Add `<monochrome>` to `ic_launcher.xml` + `ic_launcher_round.xml`; derive monochrome PNGs from the wordmark silhouette | Android-13+ themed-icon support; icon scope explicitly requested. |
| Tagline copy | New short per-locale `featureGraphicTagline` (approved set below) | Existing `short_description` (≤80 chars) is too long for a banner. |
| Output policy | The **store-render outputs** (feature graphic + store icon under `fastlane/metadata/android/*/images/`) are gitignored like the screenshots; only pipeline code is committed. The **launcher `<monochrome>` mipmaps** are committed (they are source `res/` assets, like the existing foreground PNGs). | Matches the existing screenshot policy (`Android/fastlane/.gitignore` ignores `metadata/android/*/images/`), while launcher icon layers live in version-controlled `res/`. |

## Architecture / file map

All capture code lives under `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/`.

| File | New/changed | Role |
| --- | --- | --- |
| `frame/DeviceFrame.kt` | new (extracted) | Rounded-corner clip + fake status bar + density-lowered inner app. The reusable frame core. |
| `frame/ScreenshotFrame.kt` | changed | Keeps title/subtitle bands + frame positioning; delegates the frame body to `DeviceFrame`. **Pixel-preserving.** |
| `featuregraphic/FeatureGraphicLayout.kt` | new | Data class of dimensions/colors/fonts + a `default()` factory, evaluated against the 1024×500 px canvas (density 1 wrapper, so `dp`/`sp` == px). |
| `featuregraphic/FeatureGraphic.kt` | new | The 1024×500 composition: left wordmark logo + tagline, right `DeviceFrame` wrapping a Reader scene. |
| `featuregraphic/StoreIcon.kt` | new | The 512×512 full-bleed icon composable (gradient + scaled foreground). |
| `FeatureGraphicTest.kt` | new | `@RunWith(Parameterized)` over `ScreenshotLocale`; one capture per locale → `featureGraphic/<playLocale>.png`. |
| `StoreIconTest.kt` | new | Single capture (locale-independent) → `storeIcon/icon.png`. |
| `fixtures/MarketingStrings.kt` | changed | Add a `featureGraphicTagline(tag)` lookup (5 locales). |
| `app/build.gradle.kts` | changed | Extend `collectScreenshots` `doLast` with feature-graphic + store-icon fan-out. |

Launcher icon (main source tree, `Android/app/src/main/res/`):

| File | New/changed | Role |
| --- | --- | --- |
| `mipmap-anydpi-v26/ic_launcher.xml` | changed | Add `<monochrome android:drawable="@mipmap/ic_launcher_monochrome" />`. |
| `mipmap-anydpi-v26/ic_launcher_round.xml` | changed | Same. |
| `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher_monochrome.png` | new | Single-color wordmark silhouette per density (108/162/216/324/432 px). |

fastlane (`Android/fastlane/`):

| File | New/changed | Role |
| --- | --- | --- |
| `Fastfile` | changed | Fix `PLAY_PACKAGE_NAME` default `com.keynumber.folino` → `com.harmolo.folino`. |
| `README.md` | changed | Document feature-graphic + store-icon generation; fix stale locale count (2 → 5) and package-name default. |

## Component design

### 1. `DeviceFrame` extraction (behavior-preserving refactor)

`ScreenshotFrame.kt` currently inlines the device-frame body (lines ~99–145): the positioning `Box`,
the rounded-corner `clip`, the fake status bar, the **lowered-subtree-density trick**
(`Density(frameWidthPx / innerDesignWidth.value)`, needed because Robolectric/Compose-on-device
graphicsLayer scaling mis-places content), the opaque `innerBackground` fill, the
`LocalReaderSeedLayoutWidthMm` seeding, and the `overlay()` slot.

Extract that body verbatim into:

```kotlin
@Composable
fun DeviceFrame(
    frameWidth: Dp,
    frameHeight: Dp,
    statusBarHeight: Dp,
    statusBarColor: Color,
    cornerRadius: Dp,
    innerBackground: Color,
    innerDesignWidth: Dp,
    overlay: @Composable () -> Unit = {},
    inner: @Composable () -> Unit,
)
```

`ScreenshotFrame` keeps the title/subtitle bands and the `frameTop`/`frameHeight`/`frameWidth`
derivation, then renders the frame via `DeviceFrame(...)` inside its positioning `Box`. The
`LocalReaderSeedLayoutWidthMm` provision stays inside `DeviceFrame` (it is keyed off `innerDesignWidth`,
which `DeviceFrame` receives).

Verification that this is pixel-preserving: re-record the full screenshot suite and `diff` against a
pre-refactor baseline (capture once before the change to `/tmp`), expecting byte-identical PNGs. (There
are no committed golden images.)

### 2. `FeatureGraphicLayout`

A pure data class with a `companion object default()`. The capture wraps the composable at density 1
(see `captureFixedSize`), so absolute `dp`/`sp` values are full pixels on the 1024×500 canvas.
Starting values (all tuned by render-and-Read):

| Field | Start | Notes |
| --- | --- | --- |
| `background` | `iconGradient` | white→`#CEE1FF`. |
| `horizontalPadding` | `64.dp` | Left/right inset. |
| `logoHeight` | `132.dp` | Wordmark-art height in the left column. |
| `logoForegroundScale` | `1.3f` | Scale of `ic_launcher_foreground` to crop its adaptive safe-zone padding (tuned). |
| `tagline` | per-locale | From `MarketingStrings.featureGraphicTagline(tag)`. |
| `taglineFontSize` | `34.sp` | `captionInk`, bold. |
| `taglineColor` | `captionInk` (`#1E2438`) | Readable on the light gradient. |
| `verticalSpacing` | `20.dp` | Between logo and tagline. |
| `textColumnWidthFraction` | `0.50f` | Left column share of 1024. |
| `frameHeightFraction` | `1.12f` | > 1.0 → frame taller than canvas → slight top/bottom bleed, clipped at capture bounds. |
| `frameAspectRatio` | `0.46f` | Same portrait phone ratio as `ScreenshotLayout.phone()`. |
| `frameCornerRadius` | `28.dp` | Matches the phone preset. |
| `statusBarHeight` | `0.dp` | Phone preset uses no fake status bar (the light app fills to the top). |
| `innerBackground` | `Color.White` | Opaque fill behind the Reader (the Reader page is light). |
| `innerDesignWidth` | `393.dp` | Phone width → score lays out at natural proportions. |
| `frameVerticalOffset` | `0.dp` | Tunable: nudge the frame down to trade top vs. bottom bleed. |

### 3. `FeatureGraphic`

```kotlin
@Composable
fun FeatureGraphic(tag: String, layout: FeatureGraphicLayout = FeatureGraphicLayout.default())
```

Structure:

- Root `BoxWithConstraints(Modifier.fillMaxSize().background(layout.background))`. Reads `maxWidth`/
  `maxHeight`; derives `frameHeight = canvasHeight * frameHeightFraction`,
  `frameWidth = frameHeight * frameAspectRatio`.
- **Left column** (`Alignment.CenterStart`, `padding(start = horizontalPadding)`, width =
  `canvasWidth * textColumnWidthFraction`), a `Column`:
  - `Image(painterResource(R.mipmap.ic_launcher_foreground))` at `logoHeight`, `scale(logoForegroundScale)`
    — the folino wordmark + staff, the brand logo.
  - `Spacer(verticalSpacing)`.
  - `Text(MarketingStrings.featureGraphicTagline(tag))` — `captionInk`, bold, `taglineFontSize`,
    `maxLines = 2`.
- **Right frame** (`Alignment.CenterEnd`, `padding(end = horizontalPadding)`): a `Box` of full canvas
  height, content centered, holding `DeviceFrame(frameWidth, frameHeight, ...)`. The `inner` slot is a
  **Reader sheet-music screen**, reusing the Reader scene host the screenshot scenes already use:
  `FolinoTheme { rememberReaderSceneState { LayoutOptions.DEFAULT.copy(mode = VERTICAL, staffSize =
  SCREENSHOT_STAFF_SIZE) } }` → `ReaderSceneContent(state, scoreHandle, layoutOptions, withCursor =
  true, signalReadyWhenRendered = true)`. The banner shows a clean score; the `ReaderTopBar` and
  `PlaybackFab` clutter from `ReaderCursorScene` are omitted (the banner reads better as just the
  notation) — final inclusion decided during render-tuning.
- `SceneReady` gating works as-is: the Reader scene marks the capture gated and signals ready when the
  score has rendered; `captureFixedSize` already blocks on that.

### 4. `StoreIcon` (512×512, full-bleed)

```kotlin
@Composable
fun StoreIcon(foregroundScale: Float = 1.4f)
```

`Box(Modifier.fillMaxSize().background(iconGradient))` with a centered
`Image(painterResource(R.mipmap.ic_launcher_foreground), Modifier.fillMaxSize().scale(foregroundScale))`.
**No rounded clip** — Google's Play Console applies the rounded mask, so the source must be full-bleed
with sharp corners (this is the exact bug VocalTuner's `f810450` fixed: a previously padded icon showed
a margin). The gradient matches `ic_launcher_background.xml`; the foreground is scaled up to crop its
adaptive safe-zone padding so the wordmark fills the tile the way the launcher shows it after masking.
Rendered once at 512×512; locale-independent.

### 5. Themed-icon (`<monochrome>`) layer

- Add `<monochrome android:drawable="@mipmap/ic_launcher_monochrome" />` to both
  `mipmap-anydpi-v26/ic_launcher.xml` and `ic_launcher_round.xml` (alongside the existing
  `<background>`/`<foreground>`).
- Generate `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher_monochrome.png` (108/162/216/324/432 px) as a
  **single-color silhouette of the wordmark** (alpha defines the shape; Android applies the system
  theme tint and ignores the RGB). Derived from the wordmark art — preferring the clean solid wordmark
  silhouette (`folino_icon_title`) over the faint staff lines, which read poorly when tinted. Whether to
  include the staff is decided against the themed-icon preview during implementation.
- Derivation is a small committed script (not a heredoc; written to `Android/app/.../` tooling or a
  one-off `Scripts/` helper per repo convention) using `sips`/ImageMagick to flatten RGB while keeping
  alpha and resize to each density. The generated `ic_launcher_monochrome.png` files **are** committed
  (they are source `res/`, unlike the gitignored store renders).

### 6. Tagline copy (approved)

New `featureGraphicTagline` per locale, short enough for a banner:

| Locale (tag → playLocale) | Tagline |
| --- | --- |
| `en` → en-US | Read and play your scores |
| `ja` → ja-JP | 楽譜を、読んで、鳴らす。 |
| `ko` → ko-KR | 악보를 읽고, 연주하세요 |
| `zh-Hans` → zh-CN | 读谱，奏乐，练习 |
| `zh-Hant` → zh-TW | 讀譜，奏樂，練習 |

Added to `MarketingStrings` as a `featureGraphicTagline(tag: String): String` lookup with an `en`
fallback (parallel to the existing `forScene`). A unit assertion covers the five strings.

### 7. Pipeline + fastlane wiring

**Capture entry points** (instrumented, run under `connectedDebugAndroidTest` on the emulator):

- `FeatureGraphicTest` — `@RunWith(Parameterized::class)` over `ScreenshotLocale.entries`, one
  `composeRule` per locale (one `setContent` per rule, same reason `ScreenshotTest` is parameterized).
  Each: `composeRule.captureFixedSize(1024, 500, "featureGraphic/${locale.playLocale}.png") {
  WithAppLocale(locale.tag) { FeatureGraphic(tag = locale.tag) } }`.
- `StoreIconTest` — a single `@Test`: `composeRule.captureFixedSize(512, 512, "storeIcon/icon.png") {
  StoreIcon() }`.

These land (via `TestStorage` + `useTestStorageService`) under the host tree
`app/build/outputs/connected_android_test_additional_output/debugAndroidTest/connected/<AVD>/` at the
relative paths `featureGraphic/<playLocale>.png` and `storeIcon/icon.png` — siblings of the existing
`phone/` and `tablet/` dirs.

**`collectScreenshots` extension** — two blocks added to the `doLast`, walking each per-AVD dir
(reusing the existing `additionalOutput.listFiles()` loop):

- Feature graphic: for each `<avd>/featureGraphic/<playLocale>.png`, copy to
  `Android/fastlane/metadata/android/<playLocale>/images/featureGraphic.png` (a single file per locale,
  not a directory — supply's convention).
- Store icon: the single `<avd>/storeIcon/icon.png` → copied into **every** real listing locale's
  `images/icon.png` (iterate the locale dirs, gated on `title.txt` existing, as VocalTuner does).

**fastlane**: the existing `upload_listing` lane already uploads `featureGraphic.png` + `icon.png` when
present (`skip_upload_images: false`). No lane change needed for the assets. Two fixes:

- `Fastfile` / `README.md`: change the `PLAY_PACKAGE_NAME` default from `com.keynumber.folino` to
  `com.harmolo.folino` (the actual `applicationId`; the `Appfile` already defaults correctly).
- `README.md`: document feature-graphic + store-icon generation and correct the stale "2 locales / 24
  PNGs" count to 5 locales.

> Note: the Play Developer API sometimes rejects app-icon updates (VocalTuner's `649f0d8` flagged this).
> Recommend `PLAY_VALIDATE_ONLY=1` first, with a manual Play Console upload as the fallback for `icon.png`.

## Verification model

No golden-image assertions (consistent with the existing harness). Verification is:

1. **`DeviceFrame` refactor**: capture the screenshot suite before the change to a `/tmp` baseline;
   after, re-capture and `diff -r` — expect byte-identical PNGs for all 60 screenshots.
2. **Tagline strings**: a JUnit/Swift-Testing-style unit assertion on the five `featureGraphicTagline`
   values.
3. **Feature graphic + store icon**: run the instrumented capture on the emulator (`emulator-5554`),
   then `Read` the generated PNGs and tune `FeatureGraphicLayout` / `StoreIcon` scale against explicit
   visual criteria (wordmark legible, tagline not clipped in any locale incl. CJK, frame bleed balanced,
   store icon full-bleed with no margin). Confirm dimensions with `file` (`1024 x 500`, `512 x 512`).
4. **Themed icon**: verify the monochrome layer renders in the launcher themed-icon preview.

## Risks / open questions

- **CJK tagline width**: taglines are short, but `taglineFontSize` may need reduction if a locale clips;
  verified by rendering all five.
- **Reader scene readiness in a non-standard canvas**: the feature graphic uses a different aspect ratio
  than the phone/tablet presets; the `SceneReady` gate + `LocalReaderSeedLayoutWidthMm` seeding must
  still settle the score within the 60 s bound. Mitigation: reuse the proven scene host; tune
  `innerDesignWidth`.
- **Monochrome legibility**: the faint staff lines may not tint well; fall back to a wordmark-only
  monochrome if the staff reads poorly.
- **Scoped instrumented runs**: memory notes the screenshot suite can be fragile under scoped execution;
  run the new tests with the rest of the suite (or class-scoped) and confirm the emulator is the
  configured one (`emulator-5554`).
- **Store-icon scale**: `foregroundScale` is tuned by eye to match the launcher's masked appearance;
  starting at ~1.4 (VocalTuner used 1.5 for a different mark).

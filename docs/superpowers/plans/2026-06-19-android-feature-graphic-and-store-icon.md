# Android feature graphic + store icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-generate the Play Store feature graphic (1024×500, per locale) and a full-bleed 512 store icon via Folino's existing instrumented screenshot harness, and add a themed-icon `<monochrome>` layer to the adaptive launcher icon.

**Architecture:** Extract the device-frame body from `ScreenshotFrame` into a reusable `DeviceFrame`; build a `FeatureGraphic` composable (left: wordmark logo + localized tagline, right: real Reader screen in a `DeviceFrame`) and a `StoreIcon` composable (gradient + full-bleed foreground), capture both via the existing `captureFixedSize` instrumented harness, and fan the PNGs into the fastlane supply tree by extending `collectScreenshots`. Add `<monochrome>` mipmaps derived from the foreground art.

**Tech Stack:** Kotlin, Jetpack Compose, AndroidX instrumented tests (`captureToImage`/PixelCopy + `TestStorage`), Gradle Kotlin DSL, fastlane supply. ImageMagick for monochrome PNG derivation.

## Global Constraints

- App module: `Android/` (separate Gradle project). `applicationId = com.harmolo.folino`; `namespace = com.keynumber.folino` (must not change). `minSdk = 28`, `compile/targetSdk = 35`.
- All capture code lives in the **instrumented** source set `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/` (the Reader renders sheet music via native JNI that cannot run on the host JVM — no Robolectric).
- 5 shipped locales: `en` → `en-US`, `ja` → `ja-JP`, `ko` → `ko-KR`, `zh-Hans` → `zh-CN`, `zh-Hant` → `zh-TW` (`ScreenshotLocale` is the single source of truth).
- Brand: background `iconGradient` = vertical white → `#CEE1FF` at 70%; text ink `captionInk` = `#1E2438`. Wordmark name is lowercase `folino` everywhere user-visible.
- Feature graphic: exactly **1024×500 px**, one `featureGraphic.png` per locale. Store icon: exactly **512×512 px**, full-bleed, **sharp corners** (Google applies the rounded mask).
- The `DeviceFrame` extraction (Task 1) MUST be pixel-preserving for the existing 60 screenshots (6 scenes × 5 locales × 2 devices).
- Generated store renders (feature graphic + icon under `Android/fastlane/metadata/android/*/images/`) are gitignored; pipeline code is committed. The `<monochrome>` mipmaps are committed source `res/`.
- No new third-party dependency, no new Gradle plugin.

## Preconditions

- A booted emulator at `emulator-5554` (the configured screenshot device; arm64-v8a). All instrumented runs prefix `ANDROID_SERIAL=emulator-5554`.
- The Android app builds in this checkout (native `.so` / jextract bindings already present).
- Commands below run from the `Android/` directory unless noted.
- Known gotcha: class-scoped instrumented runs have crashed this screenshot suite before. If a scoped run crashes, fall back to the full `connectedDebugAndroidTest`. Verification runs therefore use the full suite (it captures all screenshots + the new feature-graphic/icon PNGs in one pass — slower, but the safe path).

## File Structure

| File | Responsibility |
| --- | --- |
| `screenshot/frame/Brand.kt` (new) | Shared brand palette (`iconGradient`, `captionInk`) used by `ScreenshotLayout`, `FeatureGraphic`, `StoreIcon`. |
| `screenshot/frame/DeviceFrame.kt` (new) | Reusable rounded device frame: clip + status bar + density-lowered inner app. |
| `screenshot/frame/ScreenshotFrame.kt` (modified) | Title/subtitle bands + positioning; delegates frame body to `DeviceFrame`. |
| `screenshot/frame/ScreenshotLayout.kt` (modified) | References `Brand` instead of private copies (values unchanged). |
| `screenshot/featuregraphic/FeatureGraphicLayout.kt` (new) | Layout knobs for the banner + `default()`. |
| `screenshot/featuregraphic/FeatureGraphic.kt` (new) | The 1024×500 composition. |
| `screenshot/featuregraphic/StoreIcon.kt` (new) | The 512×512 full-bleed icon composable. |
| `screenshot/fixtures/MarketingStrings.kt` (modified) | Add `featureGraphicTagline(tag)`. |
| `screenshot/FeatureGraphicTest.kt` (new) | Parameterized over locale; captures the banner. |
| `screenshot/StoreIconTest.kt` (new) | Single capture of the store icon. |
| `screenshot/FeatureGraphicTaglineTest.kt` (new) | Instrumented assertion on the 5 taglines. |
| `app/build.gradle.kts` (modified) | Extend `collectScreenshots` fan-out. |
| `app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` + `ic_launcher_round.xml` (modified) | Add `<monochrome>`. |
| `app/src/main/res/mipmap-*/ic_launcher_monochrome.png` (new) | Per-density monochrome layer. |
| `Scripts/gen-monochrome-icon.sh` (new) | Reproducible monochrome PNG derivation. |
| `Android/fastlane/Fastfile` + `README.md` (modified) | Fix `PLAY_PACKAGE_NAME` default; document new assets. |

---

### Task 1: Extract `Brand` palette + `DeviceFrame` (pixel-preserving refactor)

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/Brand.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/DeviceFrame.kt`
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/ScreenshotLayout.kt`
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/ScreenshotFrame.kt`

**Interfaces:**
- Produces: `object Brand { val iconGradient: Brush; val captionInk: Color }`
- Produces: `@Composable fun DeviceFrame(frameWidth: Dp, frameHeight: Dp, statusBarHeight: Dp, statusBarColor: Color, cornerRadius: Dp, innerBackground: Color, innerDesignWidth: Dp, overlay: @Composable () -> Unit = {}, inner: @Composable () -> Unit)`

- [ ] **Step 1: Capture the pre-refactor baseline**

(run from `Android/`) Run the full instrumented suite, then snapshot its output for a byte-diff later.

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
cp -R app/build/outputs/connected_android_test_additional_output /tmp/fg-baseline
```

Expected: build + tests succeed; `/tmp/fg-baseline` holds the 60 screenshot PNGs under `.../connected/<AVD>/{phone,tablet}/<locale>/<NN>.png`.

- [ ] **Step 2: Create `Brand.kt`**

```kotlin
package com.keynumber.folino.screenshot.frame

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// Brand palette shared by the screenshot frame, the feature graphic, and the store icon.
// Marketing background = the folino app-icon fill (App/Resources/folino.icon/icon.json):
// vertical gradient white -> light blue (srgb 0.807, 0.884, 1.0 ≈ #CEE1FF) at 70% height.
// captionInk = dark navy from the icon's light-appearance title gradient (~#2E3043), readable on it.
object Brand {
    val iconGradient = Brush.verticalGradient(
        0.0f to Color.White,
        0.7f to Color(0xFFCEE1FF),
    )
    val captionInk = Color(0xFF1E2438)
}
```

- [ ] **Step 3: Point `ScreenshotLayout` at `Brand` (values unchanged)**

In `ScreenshotLayout.kt`, delete the private `iconGradient` and `captionInk` vals from the companion object and replace their references. The `phone()`/`tablet()` defaults and the two `titleColor`/`subtitleColor` assignments change from `iconGradient`/`captionInk` to `Brand.iconGradient`/`Brand.captionInk`. The literal values are identical, so output is unchanged.

Concretely: `background: Brush = iconGradient` → `background: Brush = Brand.iconGradient`; `titleColor = captionInk` → `titleColor = Brand.captionInk`; `subtitleColor = captionInk.copy(alpha = 0.72f)` → `subtitleColor = Brand.captionInk.copy(alpha = 0.72f)` (both presets).

- [ ] **Step 4: Create `DeviceFrame.kt` (verbatim cut of the frame body)**

Move the frame body (the positioning `Box` contents) out of `ScreenshotFrame` into:

```kotlin
package com.keynumber.folino.screenshot.frame

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import com.keynumber.folino.reader.LAYOUT_DP_PER_MM
import com.keynumber.folino.screenshot.fixtures.LocalReaderSeedLayoutWidthMm

// Reusable device frame extracted from ScreenshotFrame: the app screen clipped to rounded top corners,
// a fake status bar, the inner app rendered at a LOWERED subtree density (the Compose equivalent of
// rendering full-size and pasting a scaled image — graphicsLayer/canvas scaling mis-places content on
// device), an opaque innerBackground fill so the marketing gradient never bleeds through, and an
// overlay() slot drawn on top. The caller sizes and positions the frame.
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
) {
    Box(modifier = Modifier.width(frameWidth).height(frameHeight)) {
        val appSlotHeight = frameHeight - statusBarHeight
        val parentDensity = LocalDensity.current
        val frameWidthPx = with(parentDensity) { frameWidth.toPx() }
        val innerDensity = Density(
            density = frameWidthPx / innerDesignWidth.value,
            fontScale = parentDensity.fontScale,
        )
        Column(modifier = Modifier.fillMaxSize().clip(
            RoundedCornerShape(topStart = cornerRadius, topEnd = cornerRadius),
        )) {
            Box(modifier = Modifier.fillMaxWidth().height(statusBarHeight).background(statusBarColor))
            Box(
                modifier = Modifier
                    .width(frameWidth)
                    .height(appSlotHeight)
                    .background(innerBackground)
                    .clipToBounds(),
            ) {
                CompositionLocalProvider(
                    LocalDensity provides innerDensity,
                    LocalReaderSeedLayoutWidthMm provides (innerDesignWidth.value / LAYOUT_DP_PER_MM),
                ) {
                    Box(modifier = Modifier.fillMaxSize()) { inner() }
                }
            }
        }
        overlay()
    }
}
```

- [ ] **Step 5: Make `ScreenshotFrame` delegate to `DeviceFrame`**

Replace the positioning `Box`'s inline body (current `ScreenshotFrame.kt:99-145`) so the `Box` sizes/positions the frame and calls `DeviceFrame`. The `Box` keeps its `align(TopCenter)` + `padding(top = frameTop)` + `height(frameHeight)` + `width(frameWidth)`, and its single child becomes:

```kotlin
        Box(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = frameTop)
                .height(frameHeight)
                .width(frameWidth),
        ) {
            DeviceFrame(
                frameWidth = frameWidth,
                frameHeight = frameHeight,
                statusBarHeight = layout.statusBarHeight,
                statusBarColor = layout.statusBarColor,
                cornerRadius = layout.frameCornerRadius,
                innerBackground = layout.innerBackground,
                innerDesignWidth = layout.innerDesignWidth,
                overlay = overlay,
                inner = inner,
            )
        }
```

Remove the now-unused imports from `ScreenshotFrame.kt` that moved to `DeviceFrame.kt` (e.g. `clip`, `clipToBounds`, `Density`, `LocalDensity`, `RoundedCornerShape`, `CompositionLocalProvider`, `LAYOUT_DP_PER_MM`, `LocalReaderSeedLayoutWidthMm`, `Column`) if no longer referenced; keep those still used by the title/subtitle bands.

- [ ] **Step 6: Re-run the suite and verify byte-identical output**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
diff -r /tmp/fg-baseline app/build/outputs/connected_android_test_additional_output
```

Expected: `diff` reports **no differences** (the refactor is pixel-preserving).

- [ ] **Step 7: Commit**

```
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/
git commit -m "refactor(android-screenshots): extract Brand + reusable DeviceFrame from ScreenshotFrame"
```

---

### Task 2: Add `featureGraphicTagline` to `MarketingStrings`

**Files:**
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/MarketingStrings.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/FeatureGraphicTaglineTest.kt`

**Interfaces:**
- Produces: `fun MarketingStrings.featureGraphicTagline(tag: String): String`

- [ ] **Step 1: Write the failing assertion test**

```kotlin
package com.keynumber.folino.screenshot

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeatureGraphicTaglineTest {
    @Test
    fun taglinesPerLocale() {
        assertEquals("Read and play your scores", MarketingStrings.featureGraphicTagline("en"))
        assertEquals("楽譜を、読んで、鳴らす。", MarketingStrings.featureGraphicTagline("ja"))
        assertEquals("악보를 읽고, 연주하세요", MarketingStrings.featureGraphicTagline("ko"))
        assertEquals("读谱，奏乐，练习", MarketingStrings.featureGraphicTagline("zh-Hans"))
        assertEquals("讀譜，奏樂，練習", MarketingStrings.featureGraphicTagline("zh-Hant"))
    }

    @Test
    fun unknownLocaleFallsBackToEnglish() {
        assertEquals("Read and play your scores", MarketingStrings.featureGraphicTagline("xx"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails to compile / fail**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
```

Expected: compile error `unresolved reference: featureGraphicTagline` (the function does not exist yet).

- [ ] **Step 3: Add the lookup to `MarketingStrings`**

Add inside `object MarketingStrings`, after `forScene`:

```kotlin
    // Short marketing-banner tagline for the Play Store feature graphic, per language tag. Tighter than
    // the per-scene subtitles / Play short_description. Falls back to English for unknown tags.
    private val featureGraphicTaglines: Map<String, String> = mapOf(
        "en" to "Read and play your scores",
        "ja" to "楽譜を、読んで、鳴らす。",
        "ko" to "악보를 읽고, 연주하세요",
        "zh-Hans" to "读谱，奏乐，练习",
        "zh-Hant" to "讀譜，奏樂，練習",
    )

    fun featureGraphicTagline(tag: String): String =
        featureGraphicTaglines[tag] ?: featureGraphicTaglines.getValue("en")
```

- [ ] **Step 4: Run it to verify it passes**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
```

Expected: `FeatureGraphicTaglineTest` PASSES (the rest of the suite still passes too).

- [ ] **Step 5: Commit**

```
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/MarketingStrings.kt Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/FeatureGraphicTaglineTest.kt
git commit -m "feat(android-screenshots): add per-locale feature-graphic taglines"
```

---

### Task 3: `StoreIcon` composable + `FeatureGraphicLayout`

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/StoreIcon.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/FeatureGraphicLayout.kt`

**Interfaces:**
- Produces: `@Composable fun StoreIcon(foregroundScale: Float = 1.4f)`
- Produces: `data class FeatureGraphicLayout(...)` with `companion object { fun default(): FeatureGraphicLayout }`

- [ ] **Step 1: Create `StoreIcon.kt`**

```kotlin
package com.keynumber.folino.screenshot.featuregraphic

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import com.keynumber.folino.R
import com.keynumber.folino.screenshot.frame.Brand

// Full-bleed 512x512 Play Store icon: the brand gradient edge-to-edge with the adaptive-icon foreground
// (the folino wordmark + staff) scaled up to crop its adaptive safe-zone padding, so the tile reads the
// way the launcher shows it after masking. NO rounded clip — Google's Play Console applies the rounded
// mask, so the source must be full-bleed with sharp corners.
@Composable
fun StoreIcon(foregroundScale: Float = 1.4f) {
    Box(
        modifier = Modifier.fillMaxSize().background(Brand.iconGradient),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(id = R.mipmap.ic_launcher_foreground),
            contentDescription = null,
            modifier = Modifier.fillMaxSize().scale(foregroundScale),
        )
    }
}
```

- [ ] **Step 2: Create `FeatureGraphicLayout.kt`**

```kotlin
package com.keynumber.folino.screenshot.featuregraphic

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.keynumber.folino.screenshot.frame.Brand

// Layout knobs for the 1024x500 feature graphic. The capture wraps this at density 1 (see
// captureFixedSize), so absolute dp/sp values are full pixels on the 1024x500 canvas. All values are
// starting points tuned by rendering and Read-ing the PNG (see the plan's tuning task).
data class FeatureGraphicLayout(
    val background: Brush,
    val horizontalPadding: Dp,
    val logoHeight: Dp,
    val logoForegroundScale: Float,
    val taglineFontSize: TextUnit,
    val taglineColor: Color,
    val verticalSpacing: Dp,
    val textColumnWidthFraction: Float,
    val frameHeightFraction: Float,
    val frameAspectRatio: Float,
    val frameCornerRadius: Dp,
    val statusBarHeight: Dp,
    val statusBarColor: Color,
    val innerBackground: Color,
    val innerDesignWidth: Dp,
    val frameVerticalOffset: Dp,
) {
    companion object {
        fun default() = FeatureGraphicLayout(
            background = Brand.iconGradient,
            horizontalPadding = 64.dp,
            logoHeight = 132.dp,
            logoForegroundScale = 1.3f,
            taglineFontSize = 34.sp,
            taglineColor = Brand.captionInk,
            verticalSpacing = 20.dp,
            textColumnWidthFraction = 0.50f,
            frameHeightFraction = 1.12f,
            frameAspectRatio = 0.46f,
            frameCornerRadius = 28.dp,
            statusBarHeight = 0.dp,
            statusBarColor = Color.Black,
            innerBackground = Color.White,
            innerDesignWidth = 393.dp,
            frameVerticalOffset = 0.dp,
        )
    }
}
```

- [ ] **Step 3: Compile-check via the suite build**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:compileDebugAndroidTestKotlin
```

Expected: BUILD SUCCESSFUL (new files compile; `R.mipmap.ic_launcher_foreground` resolves).

- [ ] **Step 4: Commit**

```
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/
git commit -m "feat(android-screenshots): add StoreIcon composable and FeatureGraphicLayout"
```

---

### Task 4: `FeatureGraphic` composable

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/FeatureGraphic.kt`

**Interfaces:**
- Consumes: `DeviceFrame` (Task 1), `FeatureGraphicLayout` (Task 3), `MarketingStrings.featureGraphicTagline` (Task 2), and the Reader scene fixtures used by `ReaderCursorScene` (`rememberReaderSceneState`, `ReaderSceneContent`, `SCREENSHOT_STAFF_SIZE`).
- Produces: `@Composable fun FeatureGraphic(tag: String, layout: FeatureGraphicLayout = FeatureGraphicLayout.default())`

- [ ] **Step 1: Read the reference scene**

Read `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/ReaderCursorScene.kt` and `fixtures/SceneReady.kt` / `fixtures/ReaderSceneHost.kt` to mirror the exact Reader-scene gating (`rememberReaderSceneState` + `ReaderSceneContent`). The inner score must mark the `SceneReady` capture gate so `captureFixedSize` waits for the rendered score. Use `signalReadyWhenRendered = true` (the banner has no transport FAB / audio VM to also wait on).

- [ ] **Step 2: Create `FeatureGraphic.kt`**

```kotlin
package com.keynumber.folino.screenshot.featuregraphic

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import com.keynumber.folino.R
import com.keynumber.folino.reader.LayoutOptions
import com.keynumber.folino.reader.ReaderLayoutMode
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.ReaderSceneContent
import com.keynumber.folino.screenshot.fixtures.SCREENSHOT_STAFF_SIZE
import com.keynumber.folino.screenshot.fixtures.rememberReaderSceneState
import com.keynumber.folino.screenshot.frame.DeviceFrame
import com.keynumber.folino.ui.theme.FolinoTheme

// The 1024x500 Play Store feature graphic. Left: the folino wordmark logo (the adaptive-icon foreground
// art — the wordmark IS the brand mark, so no separate app-name text) + the localized tagline. Right: a
// real Reader sheet-music screen in a DeviceFrame, vertically centered and taller than the canvas so it
// bleeds slightly off the top/bottom (clipped at the capture bounds). Background: the brand gradient.
@Composable
fun FeatureGraphic(tag: String, layout: FeatureGraphicLayout = FeatureGraphicLayout.default()) {
    BoxWithConstraints(modifier = Modifier.fillMaxSize().background(layout.background)) {
        val canvasWidth = maxWidth
        val canvasHeight = maxHeight
        val frameHeight = canvasHeight * layout.frameHeightFraction
        val frameWidth = frameHeight * layout.frameAspectRatio

        // Left column: wordmark logo + tagline, vertically centered.
        Column(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = layout.horizontalPadding)
                .width(canvasWidth * layout.textColumnWidthFraction),
            verticalArrangement = Arrangement.Center,
        ) {
            Image(
                painter = painterResource(id = R.mipmap.ic_launcher_foreground),
                contentDescription = null,
                modifier = Modifier.height(layout.logoHeight).scale(layout.logoForegroundScale),
            )
            Spacer(modifier = Modifier.height(layout.verticalSpacing))
            Text(
                text = MarketingStrings.featureGraphicTagline(tag),
                color = layout.taglineColor,
                fontSize = layout.taglineFontSize,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
            )
        }

        // Right: the Reader screen in a device frame, centered, with optional vertical offset.
        Box(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = layout.horizontalPadding)
                .fillMaxHeight(),
            contentAlignment = Alignment.Center,
        ) {
            Box(modifier = Modifier.offset(y = layout.frameVerticalOffset)) {
                DeviceFrame(
                    frameWidth = frameWidth,
                    frameHeight = frameHeight,
                    statusBarHeight = layout.statusBarHeight,
                    statusBarColor = layout.statusBarColor,
                    cornerRadius = layout.frameCornerRadius,
                    innerBackground = layout.innerBackground,
                    innerDesignWidth = layout.innerDesignWidth,
                ) {
                    FolinoTheme {
                        val scene = rememberReaderSceneState {
                            LayoutOptions.DEFAULT.copy(
                                mode = ReaderLayoutMode.VERTICAL,
                                staffSize = SCREENSHOT_STAFF_SIZE,
                            )
                        }
                        if (scene != null) {
                            ReaderSceneContent(
                                state = scene.state,
                                scoreHandle = scene.scoreHandle,
                                layoutOptions = scene.layoutOptions,
                                withCursor = true,
                                signalReadyWhenRendered = true,
                            )
                        }
                    }
                }
            }
        }
    }
}
```

> If the exact `rememberReaderSceneState` / `ReaderSceneContent` signatures differ from `ReaderCursorScene` usage, match the real ones read in Step 1. The cursor placement and score-handle wiring must mirror `ReaderCursorScene`.

- [ ] **Step 3: Compile-check**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:compileDebugAndroidTestKotlin
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/FeatureGraphic.kt
git commit -m "feat(android-screenshots): add FeatureGraphic banner composable"
```

---

### Task 5: Capture tests (`FeatureGraphicTest`, `StoreIconTest`)

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/FeatureGraphicTest.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/StoreIconTest.kt`

**Interfaces:**
- Consumes: `ComposeContentTestRule.captureFixedSize` (existing), `FeatureGraphic` (Task 4), `StoreIcon` (Task 3), `WithAppLocale` (existing), `ScreenshotLocale` (existing).
- Produces: device-side captures `featureGraphic/<playLocale>.png` (1024×500) and `storeIcon/icon.png` (512×512).

- [ ] **Step 1: Create `FeatureGraphicTest.kt`**

```kotlin
package com.keynumber.folino.screenshot

import androidx.compose.ui.test.junit4.createComposeRule
import com.keynumber.folino.screenshot.featuregraphic.FeatureGraphic
import com.keynumber.folino.screenshot.fixtures.WithAppLocale
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

// Captures the 1024x500 Play Store feature graphic, one per locale. Parameterized so each capture gets a
// fresh ComposeContentTestRule (a rule permits exactly one setContent). Output: featureGraphic/<playLocale>.png
@RunWith(Parameterized::class)
class FeatureGraphicTest(private val locale: ScreenshotLocale) {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun capture() {
        val path = "featureGraphic/${locale.playLocale}.png"
        composeRule.captureFixedSize(widthPx = 1024, heightPx = 500, filePath = path) {
            WithAppLocale(locale.tag) {
                FeatureGraphic(tag = locale.tag)
            }
        }
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = ScreenshotLocale.entries.map { arrayOf(it) }
    }
}
```

- [ ] **Step 2: Create `StoreIconTest.kt`**

```kotlin
package com.keynumber.folino.screenshot

import androidx.compose.ui.test.junit4.createComposeRule
import com.keynumber.folino.screenshot.featuregraphic.StoreIcon
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.JUnit4

// Captures the full-bleed 512x512 Play Store icon (locale-independent — the wordmark is the same in
// every locale). Output: storeIcon/icon.png
@RunWith(JUnit4::class)
class StoreIconTest {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun capture() {
        composeRule.captureFixedSize(widthPx = 512, heightPx = 512, filePath = "storeIcon/icon.png") {
            StoreIcon()
        }
    }
}
```

- [ ] **Step 3: Run the suite and confirm the new PNGs land**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
find app/build/outputs/connected_android_test_additional_output -name '*.png' -path '*featureGraphic*' -o -name 'icon.png' -path '*storeIcon*'
file app/build/outputs/connected_android_test_additional_output/*/*/featureGraphic/en-US.png
```

Expected: 5 `featureGraphic/<locale>.png` + 1 `storeIcon/icon.png` exist under the per-AVD dir; `file` reports `1024 x 500`. (If a class-scoped run was attempted and crashed, use the full suite as above.)

- [ ] **Step 4: Commit**

```
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/FeatureGraphicTest.kt Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/StoreIconTest.kt
git commit -m "feat(android-screenshots): capture feature graphic + store icon"
```

---

### Task 6: Extend `collectScreenshots` to fan out the new assets

**Files:**
- Modify: `Android/app/build.gradle.kts` (the `collectScreenshots` task, lines ~121-151)

**Interfaces:**
- Consumes: device-side captures `featureGraphic/<playLocale>.png`, `storeIcon/icon.png` (Task 5).
- Produces: `Android/fastlane/metadata/android/<playLocale>/images/featureGraphic.png` (per locale) and `.../images/icon.png` (every locale).

- [ ] **Step 1: Add two fan-out blocks inside the `doLast`**

Inside `collectScreenshots`'s `doLast`, the existing loop walks `additionalOutput.listFiles()` (the per-AVD dirs) and copies `phone`/`tablet` PNGs. Add, inside that same `avdDir` loop (after the `deviceAliasToImageDir.forEach { ... }` block), feature-graphic + store-icon handling:

```kotlin
            // Feature graphic: <avd>/featureGraphic/<playLocale>.png -> <playLocale>/images/featureGraphic.png
            val featureGraphicDir = avdDir.resolve("featureGraphic")
            if (featureGraphicDir.exists()) {
                featureGraphicDir.listFiles()?.filter { it.extension == "png" }?.forEach { png ->
                    val target = fastlaneRoot.resolve("${png.nameWithoutExtension}/images")
                    target.mkdirs()
                    png.copyTo(target.resolve("featureGraphic.png"), overwrite = true)
                    copied++
                }
            }

            // Store icon: the single <avd>/storeIcon/icon.png -> every real listing locale's images/icon.png.
            val storeIcon = avdDir.resolve("storeIcon/icon.png")
            if (storeIcon.exists()) {
                fastlaneRoot.listFiles()
                    ?.filter { it.isDirectory && it.resolve("title.txt").exists() }
                    ?.forEach { localeDir ->
                        val target = localeDir.resolve("images")
                        target.mkdirs()
                        storeIcon.copyTo(target.resolve("icon.png"), overwrite = true)
                        copied++
                    }
            }
```

(The `copied` counter and `fastlaneRoot` are already declared in the task.)

- [ ] **Step 2: Run the collect task and verify the supply tree**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:collectScreenshots
ls Android/fastlane/metadata/android/en-US/images/featureGraphic.png Android/fastlane/metadata/android/ja-JP/images/icon.png
git check-ignore Android/fastlane/metadata/android/en-US/images/featureGraphic.png
```

Expected: `collectScreenshots` prints a non-zero collected count; the listed files exist; `git check-ignore` confirms the generated PNGs are gitignored.

- [ ] **Step 3: Commit**

```
git add Android/app/build.gradle.kts
git commit -m "build(android-screenshots): fan feature graphic + store icon into the fastlane tree"
```

---

### Task 7: Render, inspect, and tune the layout

**Files:**
- Modify (as needed): `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/FeatureGraphicLayout.kt`, `StoreIcon.kt`

**Interfaces:** none new — tuning only.

- [ ] **Step 1: Read the rendered assets**

Use the Read tool on the generated PNGs (the run from Task 5/6 produced them):
- `app/build/outputs/connected_android_test_additional_output/<...>/<AVD>/featureGraphic/en-US.png`
- `.../featureGraphic/ja-JP.png` (and ko-KR, zh-CN, zh-TW)
- `.../<AVD>/storeIcon/icon.png`

- [ ] **Step 2: Evaluate against explicit criteria**

Feature graphic:
- Wordmark logo legible, not clipped, balanced against the right frame.
- Tagline in `captionInk`, not clipped in ANY locale (check CJK widths); reduce `taglineFontSize` or widen `textColumnWidthFraction` if it wraps badly.
- Right device frame shows the REAL score (not blank). A blank score means the `SceneReady` gate fired before the Reader rendered — re-check the gating wiring from Task 4 Step 1.
- Frame bleed balanced top/bottom; adjust `frameHeightFraction` / `frameVerticalOffset`.
- Frame contrast against the light gradient is adequate (the white `innerBackground` + rounded corners should read as a device; if it disappears into the gradient, consider a subtle outer shadow/border in a follow-up — do NOT add unless needed).

Store icon:
- Full-bleed (no margin/padding visible); wordmark fills the tile like the launcher icon after masking. Adjust `StoreIcon` `foregroundScale` (start 1.4).
- Sharp corners (no rounded clip in the source).

- [ ] **Step 3: Adjust layout values and re-render**

Edit `FeatureGraphicLayout.default()` and/or `StoreIcon`'s `foregroundScale`, then re-run:

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
```

Re-Read the PNGs. Repeat until the criteria are met. (Each iteration runs the full suite — this is the safe runner for this harness; budget for several minutes per pass.)

- [ ] **Step 4: Commit the tuned values**

```
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/featuregraphic/
git commit -m "style(android-screenshots): tune feature graphic + store icon composition"
```

---

### Task 8: Themed-icon (`<monochrome>`) layer

**Files:**
- Create: `Scripts/gen-monochrome-icon.sh`
- Create: `Android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_monochrome.png`
- Modify: `Android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
- Modify: `Android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml`

**Interfaces:** none (resource assets).

- [ ] **Step 1: Write the derivation script**

Create `Scripts/gen-monochrome-icon.sh` (a real script, not a heredoc; tracked because it is reproducible asset tooling):

```bash
#!/usr/bin/env bash
# Derive the adaptive-icon <monochrome> layer from the existing foreground PNGs.
# Flattens RGB to a single dark color while preserving alpha (Android applies the system theme tint and
# uses only the alpha shape). Run from the repo root. Requires ImageMagick (`magick`).
set -euo pipefail
RES="Android/app/src/main/res"
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  src="$RES/mipmap-$d/ic_launcher_foreground.png"
  out="$RES/mipmap-$d/ic_launcher_monochrome.png"
  magick "$src" -channel RGB -fill black -colorize 100 +channel "$out"
  echo "wrote $out"
done
```

- [ ] **Step 2: Generate the monochrome PNGs**

```
chmod +x Scripts/gen-monochrome-icon.sh
Scripts/gen-monochrome-icon.sh
file Android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_monochrome.png
```

Expected: 5 `ic_launcher_monochrome.png` written; `file` reports a 432×432 (xxxhdpi) PNG with alpha.

- [ ] **Step 3: Reference `<monochrome>` in both adaptive-icon XMLs**

`ic_launcher.xml` and `ic_launcher_round.xml` each become:

```xml
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
```

- [ ] **Step 4: Build the app and inspect the themed icon**

```
ANDROID_SERIAL=emulator-5554 ./gradlew :app:assembleDebug
ANDROID_SERIAL=emulator-5554 ./gradlew :app:installDebug
```

Then on the emulator enable themed icons (Settings → Wallpaper & style → Themed icons) and Read a launcher screenshot, OR inspect via the launcher. Confirm the monochrome wordmark tints legibly. If the faint staff lines read poorly, regenerate the monochrome from a wordmark-only source (the iOS `App/Resources/folino.icon/Assets/folino_icon_title.png`, resized per density) and re-run.

- [ ] **Step 5: Commit**

```
git add Scripts/gen-monochrome-icon.sh Android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml Android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml Android/app/src/main/res/mipmap-mdpi/ic_launcher_monochrome.png Android/app/src/main/res/mipmap-hdpi/ic_launcher_monochrome.png Android/app/src/main/res/mipmap-xhdpi/ic_launcher_monochrome.png Android/app/src/main/res/mipmap-xxhdpi/ic_launcher_monochrome.png Android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_monochrome.png
git commit -m "feat(android): add themed-icon monochrome layer to the adaptive launcher icon"
```

---

### Task 9: fastlane package-name fix + README

**Files:**
- Modify: `Android/fastlane/Fastfile`
- Modify: `Android/fastlane/README.md`

**Interfaces:** none.

- [ ] **Step 1: Fix the `PLAY_PACKAGE_NAME` default in `Fastfile`**

In `Android/fastlane/Fastfile`, change the `PLAY_PACKAGE_NAME` default from `com.keynumber.folino` to `com.harmolo.folino` (the actual `applicationId`; `Appfile` already defaults correctly). Locate the `ENV["PLAY_PACKAGE_NAME"] || "com.keynumber.folino"` (or equivalent) and replace the literal.

- [ ] **Step 2: Update `README.md`**

In `Android/fastlane/README.md`: change the same package-name default; correct the stale "2 locales (en-US, ja-JP) = 24 PNGs" to the actual 5 locales (en-US, ja-JP, ko-KR, zh-CN, zh-TW); add a short section documenting that `collectScreenshots` now also emits `images/featureGraphic.png` (per locale) and `images/icon.png` (every locale), and that `upload_listing` uploads them. Note: the Play Developer API can reject icon updates — run with `PLAY_VALIDATE_ONLY=1` first; manual Play Console upload is the fallback for `icon.png`.

- [ ] **Step 3: Sanity-check fastlane config parses**

```
ANDROID_SERIAL=emulator-5554 bundle exec fastlane lanes
```

(run from `Android/`) Expected: lanes list prints without a Ruby error. (If `bundle`/fastlane isn't set up in this environment, skip — this is a literal-string edit; verify by re-reading the file.)

- [ ] **Step 4: Commit**

```
git add Android/fastlane/Fastfile Android/fastlane/README.md
git commit -m "build(fastlane): fix Android Play package-name default; document feature graphic + icon"
```

---

## Self-Review

**Spec coverage:**
- Feature graphic (1024×500, per locale, brand gradient, wordmark + tagline left, Reader frame right) → Tasks 3,4,5,7. ✓
- 512 full-bleed store icon → Tasks 3,5,7. ✓
- `<monochrome>` themed-icon layer → Task 8. ✓
- `DeviceFrame` extraction, pixel-preserving → Task 1 (byte-diff verify). ✓
- `featureGraphicTagline` (approved 5 strings) → Task 2. ✓
- `collectScreenshots` fan-out → Task 6. ✓
- fastlane `PLAY_PACKAGE_NAME` fix + README locale count → Task 9. ✓
- Output policy (renders gitignored, monochrome committed) → Task 6 Step 2 check + Task 8 commit. ✓
- Verification model (byte-diff refactor / string assert / render-and-Read / themed-icon preview) → Tasks 1,2,7,8. ✓

**Placeholder scan:** No TBD/TODO. The render-tuning steps (Task 7) and the monochrome staff fallback (Task 8) are explicit, criteria-driven tuning loops — consistent with the spec's render-and-Read verification model, not vague placeholders. Layout numbers are concrete starting values.

**Type consistency:** `Brand.iconGradient`/`Brand.captionInk` (Task 1) used in Tasks 3,4. `DeviceFrame(...)` signature (Task 1) matches the call sites in `ScreenshotFrame` (Task 1) and `FeatureGraphic` (Task 4). `FeatureGraphicLayout` fields (Task 3) match `FeatureGraphic` references (Task 4). `MarketingStrings.featureGraphicTagline(tag)` (Task 2) matches the call in Task 4. `captureFixedSize(widthPx, heightPx, filePath, content)` matches the real harness signature. Capture paths `featureGraphic/<playLocale>.png` + `storeIcon/icon.png` (Task 5) match the gradle fan-out (Task 6).

**Open dependency to confirm at execution:** `rememberReaderSceneState` / `ReaderSceneContent` exact signatures + `SceneReady` gating (Task 4 Step 1 reads them before coding). If they differ from the `ReaderCursorScene` usage shown, match the real ones.

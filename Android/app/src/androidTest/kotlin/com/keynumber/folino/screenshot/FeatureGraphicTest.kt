package com.keynumber.folino.screenshot

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.screenshot.featuregraphic.FeatureGraphic
import com.keynumber.folino.screenshot.featuregraphic.FeatureGraphicLayout
import com.keynumber.folino.screenshot.fixtures.WithAppLocale
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

// Captures the Play Store feature graphic, one per locale.
//
// Resolution is controlled by the `fgScale` instrumentation argument:
//   - unset / 1  -> 1024x500 at the base layout. Portrait-safe, so the full screenshot suite can run this
//                   class harmlessly. (This direct 1x output is NOT the shipped store asset.)
//   - 2          -> 2048x1000 at FeatureGraphicLayout.scaledBy(2f) — a TRUE 2x render for supersampling.
//                   Downsampled to 1024x500 with a high-quality filter, the staff lines resolve fine
//                   (SSAA). A 2048px-wide canvas only fits the capture window in LANDSCAPE, so the 2x path
//                   must run with the emulator rotated — Scripts/render-feature-graphic.sh handles the
//                   rotation, the `fgScale=2` arg, and the downsample into the fastlane tree.
//
// Pass it as: -Pandroid.testInstrumentationRunnerArguments.fgScale=2
@RunWith(Parameterized::class)
class FeatureGraphicTest(private val locale: ScreenshotLocale) {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun capture() {
        val scale = InstrumentationRegistry.getArguments().getString("fgScale")?.toIntOrNull() ?: 1
        val layout = FeatureGraphicLayout.default().let { if (scale > 1) it.scaledBy(scale.toFloat()) else it }
        val path = "featureGraphic/${locale.playLocale}.png"
        composeRule.captureFixedSize(widthPx = 1024 * scale, heightPx = 500 * scale, filePath = path) {
            WithAppLocale(locale.tag) {
                FeatureGraphic(tag = locale.tag, layout = layout)
            }
        }
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = ScreenshotLocale.entries.map { arrayOf(it) }
    }
}

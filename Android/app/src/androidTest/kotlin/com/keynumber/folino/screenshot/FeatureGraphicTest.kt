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

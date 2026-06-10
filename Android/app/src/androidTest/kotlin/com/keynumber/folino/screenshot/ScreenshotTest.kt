package com.keynumber.folino.screenshot

import androidx.compose.ui.test.junit4.createComposeRule
import com.keynumber.folino.screenshot.fixtures.WithAppLocale
import com.keynumber.folino.screenshot.scenes.Scene
import com.keynumber.folino.screenshot.scenes.Scenes
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

// Captures every Device × Locale × Scene combination on the connected device.
//
// Parameterized so each capture is its OWN test instance: a `ComposeContentTestRule` permits exactly
// one `setContent`, so a single test iterating all combinations would throw on the second capture.
// JUnit's Parameterized runner constructs a fresh ScreenshotTest (and thus a fresh `composeRule`) per
// case, giving each capture a clean rule.
//
// Output (in-test path): <roborazziOutputDir>/<device.alias>/<locale.playLocale>/<NN>.png
@RunWith(Parameterized::class)
class ScreenshotTest(
    private val device: Device,
    private val locale: ScreenshotLocale,
    private val scene: Scene,
) {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun capture() {
        val order = scene.order.toString().padStart(2, '0')
        val path = "${device.alias}/${locale.playLocale}/$order.png"
        composeRule.captureFixedSize(device.widthPx, device.heightPx, path) {
            WithAppLocale(locale.tag) {
                scene.content(device.layout(), locale.tag)
            }
        }
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}-{1}-{2}")
        fun cases(): List<Array<Any>> = buildList {
            for (device in Device.entries) {
                for (locale in ScreenshotLocale.entries) {
                    for (scene in Scenes.all) {
                        add(arrayOf(device, locale, scene))
                    }
                }
            }
        }
    }
}

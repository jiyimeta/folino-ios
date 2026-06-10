package com.keynumber.folino.screenshot

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.keynumber.folino.screenshot.scenes.Scenes
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

// Captures every Device × Locale × Scene combination on the connected device.
// Output (in-test path): outputs/roborazzi/<device.alias>/<locale.playLocale>/<NN>.png
@RunWith(AndroidJUnit4::class)
class ScreenshotTest {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun captureAll() {
        for (device in Device.entries) {
            for (locale in ScreenshotLocale.entries) {
                for (scene in Scenes.all) {
                    val order = scene.order.toString().padStart(2, '0')
                    val path = "outputs/roborazzi/${device.alias}/${locale.playLocale}/$order.png"
                    composeRule.captureFixedSize(device.widthPx, device.heightPx, path) {
                        scene.content(device.layout(), locale.tag)
                    }
                }
            }
        }
    }
}

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

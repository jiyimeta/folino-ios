package com.keynumber.folino.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage

// Renders `content` inside a Box sized to exactly (widthPx × heightPx) device pixels by forcing a
// density of 1.0 for the wrapper (so 1.dp == 1px at this level; the frame's own inner density
// override still scales the app subtree). Captures the root node to `filePath`.
fun ComposeContentTestRule.captureFixedSize(
    widthPx: Int,
    heightPx: Int,
    filePath: String,
    content: @Composable () -> Unit,
) {
    setContent {
        CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1f)) {
            Box(modifier = Modifier.size(widthPx.dp, heightPx.dp)) { content() }
        }
    }
    onRoot().captureRoboImage(filePath = filePath)
}

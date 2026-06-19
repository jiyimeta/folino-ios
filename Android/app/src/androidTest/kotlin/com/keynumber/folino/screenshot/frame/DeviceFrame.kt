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

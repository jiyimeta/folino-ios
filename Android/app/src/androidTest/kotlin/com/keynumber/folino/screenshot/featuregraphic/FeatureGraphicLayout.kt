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

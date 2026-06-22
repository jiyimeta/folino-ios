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
    // The folino wordmark logo (the icon's title layer — drawable folino_wordmark), used in place of a
    // separate app-icon badge + app-name text: the logo already IS the brand name, so showing both was
    // redundant. logoColor tints the (black source) wordmark to the brand ink.
    val logoHeight: Dp,
    val logoColor: Color,
    // Horizontal nudge of the logo from its centered position (negative = left), for visual balance.
    val logoOffsetX: Dp,
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
    // Gap from the canvas top to the frame's rounded top edge. The frame is top-anchored: its rounded
    // top + the shadow stay visible inside the canvas and only the bottom bleeds off (clipped at the
    // capture bounds), so it reads as a device/page card rather than a full-bleed rectangle.
    val frameTopMargin: Dp,
    // Drop-shadow elevation behind the frame, to lift the (white) score card off the light gradient.
    val frameElevation: Dp,
) {
    // Scale every absolute dp/sp dimension by `factor`, leaving the canvas-relative fractions, colors, and
    // text unchanged. Renders the SAME composition at a higher pixel resolution — e.g. a true 2x SNS export
    // captured in a landscape emulator window (where the window's long edge becomes the width, so a
    // 2048px-wide canvas fits and needs no upscaling).
    //
    // `innerDesignWidth` is deliberately NOT scaled: the score's shown width in mm is innerDesignWidth /
    // LAYOUT_DP_PER_MM (independent of the frame's pixel size), so keeping it constant preserves the zoom
    // while the (now 2x-larger) frame renders the score into 2x the pixels — i.e. true higher-resolution
    // notation, not a more-pulled-back view.
    fun scaledBy(factor: Float) = copy(
        horizontalPadding = horizontalPadding * factor,
        logoHeight = logoHeight * factor,
        logoOffsetX = logoOffsetX * factor,
        taglineFontSize = taglineFontSize * factor,
        verticalSpacing = verticalSpacing * factor,
        frameCornerRadius = frameCornerRadius * factor,
        statusBarHeight = statusBarHeight * factor,
        frameTopMargin = frameTopMargin * factor,
        frameElevation = frameElevation * factor,
    )

    companion object {
        fun default() = FeatureGraphicLayout(
            background = Brand.iconGradient,
            horizontalPadding = 64.dp,
            logoHeight = 130.dp,
            logoColor = Brand.captionInk,
            logoOffsetX = (-14).dp,
            taglineFontSize = 32.sp,
            taglineColor = Brand.captionInk.copy(alpha = 0.78f),
            verticalSpacing = 24.dp,
            textColumnWidthFraction = 0.42f,
            // A tall frame that bleeds off the bottom (only the rounded top shows). The live score reflows
            // into the frame and fills it; a narrow innerDesignWidth (below) zooms the notation to fewer,
            // larger measures and raises its render density so the staff lines read fine rather than heavy.
            frameHeightFraction = 1.8f,
            frameAspectRatio = 0.46f,
            frameCornerRadius = 30.dp,
            statusBarHeight = 0.dp,
            statusBarColor = Color.Black,
            innerBackground = Color.White,
            // Score zoom: the shown width in mm = innerDesignWidth / LAYOUT_DP_PER_MM. A natural, slightly
            // pulled-back view (more measures than a tight close-up). Line crispness no longer depends on
            // this value — the store asset is rendered at 2x and downsampled (SSAA), so the staff lines stay
            // fine. Tuned by render.
            innerDesignWidth = 380.dp,
            frameTopMargin = 36.dp,
            frameElevation = 22.dp,
        )
    }
}

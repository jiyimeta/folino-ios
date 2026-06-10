package com.keynumber.folino.screenshot.frame

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

// Accent color for the marketing overlay primitives (arrow / annotation / ellipse). Approximates
// iOS's `.pink` default (systemPink, ~#FF2D55), which the iOS scenes use for all annotations.
val AnnotationPink = Color(0xFFFF2D55)

// Port of iOS Screenshot/ScreenshotLayout.swift. All `*Fraction` values are fractions of the full
// canvas height. The title and subtitle are top-anchored bands; the device frame is centered
// horizontally and sized by `frameHeightFraction` × `frameAspectRatio`. The frame may extend past
// the bottom edge (clipped by the canvas) so the app screen can be shown larger.
data class ScreenshotLayout(
    val titleTopFraction: Float,
    val subtitleTopFraction: Float,
    val frameTopFraction: Float,
    val frameHeightFraction: Float,
    val titleFontSize: TextUnit,
    val subtitleFontSize: TextUnit,
    val titleColor: Color,
    val subtitleColor: Color,
    val horizontalPadding: Dp,
    val frameAspectRatio: Float,      // device-frame width / height
    val frameCornerRadius: Dp,
    val statusBarHeight: Dp,
    val statusBarColor: Color,
    // Opaque fill painted behind the app screen so the marketing background gradient never shows
    // through transparent areas of the app content.
    val innerBackground: Color,
    // True for the tablet preset. Scenes use it to pick device-specific overlay coordinates
    // (the tablet frame is wider and shows a larger note range, so annotations targeting a specific
    // UI element land at different fractions) — mirrors the iOS scenes' `idiom.pick(...)`.
    val isTablet: Boolean,
    // Width (in dp) the inner app screen is composed at BEFORE being scaled down into the device
    // frame. Set to a realistic device width so the app lays out at natural element proportions;
    // ScreenshotFrame then renders it into the smaller frame slot via a lowered subtree density —
    // the Compose equivalent of rendering full-size and pasting a scaled image. Without this the
    // app would compose directly into the narrow frame and its controls/text would look oversized.
    val innerDesignWidth: Dp,
    val background: Brush,
) {
    companion object {
        // Marketing background = the folino app-icon fill (App/Resources/folino.icon/icon.json):
        // a vertical gradient from white at the top to a light blue (srgb 0.807, 0.884, 1.0 ≈
        // #CEE1FF) at 70% height. Matches the brand icon so the store listing reads as folino.
        private val iconGradient = Brush.verticalGradient(
            0.0f to Color.White,
            0.7f to Color(0xFFCEE1FF),
        )

        // Dark navy ink for caption text — readable on the light icon gradient (white captions
        // would vanish). Derived from the icon's light-appearance title gradient (~#2E3043).
        private val captionInk = Color(0xFF1E2438)

        fun phone(
            statusBarColor: Color = Color.Black,
            innerBackground: Color = Color.Black,
            background: Brush = iconGradient,
        ) = ScreenshotLayout(
            titleTopFraction = 0.025f,
            subtitleTopFraction = 0.095f,
            frameTopFraction = 0.165f,
            frameHeightFraction = 0.96f,
            titleFontSize = 54.sp,
            subtitleFontSize = 32.sp,
            titleColor = captionInk,
            subtitleColor = captionInk.copy(alpha = 0.72f),
            horizontalPadding = 20.dp,
            frameAspectRatio = 0.46f,
            frameCornerRadius = 28.dp,
            // No fake status-bar strip: a solid bar reads as an out-of-place black band over the
            // (light) app content. The app fills the rounded frame to the top instead. (The PiP
            // scene draws its own status bar inside its dark home, so it's unaffected.)
            statusBarHeight = 0.dp,
            statusBarColor = statusBarColor,
            innerBackground = innerBackground,
            isTablet = false,
            innerDesignWidth = 393.dp,
            background = background,
        )

        fun tablet(
            statusBarColor: Color = Color.Black,
            innerBackground: Color = Color.Black,
            background: Brush = iconGradient,
        ) = ScreenshotLayout(
            titleTopFraction = 0.03f,
            subtitleTopFraction = 0.09f,
            frameTopFraction = 0.18f,
            frameHeightFraction = 0.83f,
            titleFontSize = 72.sp,
            subtitleFontSize = 44.sp,
            titleColor = captionInk,
            subtitleColor = captionInk.copy(alpha = 0.72f),
            horizontalPadding = 56.dp,
            frameAspectRatio = 0.75f,
            frameCornerRadius = 24.dp,
            statusBarHeight = 0.dp,
            statusBarColor = statusBarColor,
            innerBackground = innerBackground,
            isTablet = true,
            innerDesignWidth = 800.dp,
            background = background,
        )
    }
}

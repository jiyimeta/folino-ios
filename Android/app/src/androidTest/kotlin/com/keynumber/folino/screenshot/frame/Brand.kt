package com.keynumber.folino.screenshot.frame

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

// Brand palette shared by the screenshot frame, the feature graphic, and the store icon.
// Marketing background = the folino app-icon fill (App/Resources/folino.icon/icon.json):
// vertical gradient white -> light blue (srgb 0.807, 0.884, 1.0 ≈ #CEE1FF) at 70% height.
// captionInk = dark navy from the icon's light-appearance title gradient (~#2E3043), readable on it.
object Brand {
    val iconGradient = Brush.verticalGradient(
        0.0f to Color.White,
        0.7f to Color(0xFFCEE1FF),
    )
    val captionInk = Color(0xFF1E2438)
}

package com.keynumber.folino.reader.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/** A metronome icon (outline). The bundled Material icon set has no metronome glyph. */
val MetronomeIcon: ImageVector = ImageVector.Builder(
    name = "Metronome",
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).apply {
    // Trapezoid body (narrow top, wide base)
    path(
        stroke = SolidColor(Color.White),
        strokeLineWidth = 2f,
        strokeLineJoin = StrokeJoin.Round,
        strokeLineCap = StrokeCap.Round,
    ) {
        moveTo(9f, 3f); lineTo(15f, 3f); lineTo(19.5f, 21f); lineTo(4.5f, 21f); close()
    }
    // Pendulum rod
    path(stroke = SolidColor(Color.White), strokeLineWidth = 2f, strokeLineCap = StrokeCap.Round) {
        moveTo(12f, 19.5f); lineTo(15f, 6.5f)
    }
    // Pendulum weight
    path(stroke = SolidColor(Color.White), strokeLineWidth = 2f, strokeLineCap = StrokeCap.Round) {
        moveTo(12.6f, 12.5f); lineTo(15.2f, 12.5f)
    }
}.build()

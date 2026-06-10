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

/**
 * A transpose icon: a sharp (♯) beside a flat (♭). Distinguishes the transpose control from the
 * vertical-scroll layout glyph (both were vertical double-arrows before). No bundled Material glyph
 * exists for sharp/flat, so it is hand-authored as stroked paths (white stroke so [Icon] tint applies).
 */
val TransposeIcon: ImageVector = ImageVector.Builder(
    name = "Transpose",
    defaultWidth = 24.dp,
    defaultHeight = 24.dp,
    viewportWidth = 24f,
    viewportHeight = 24f,
).apply {
    // Sharp (♯): two near-vertical bars + two up-slanting horizontal bars.
    path(stroke = SolidColor(Color.White), strokeLineWidth = 1.8f, strokeLineCap = StrokeCap.Round) {
        moveTo(5f, 7f); lineTo(5f, 16.5f)
    }
    path(stroke = SolidColor(Color.White), strokeLineWidth = 1.8f, strokeLineCap = StrokeCap.Round) {
        moveTo(8.5f, 7.5f); lineTo(8.5f, 17f)
    }
    path(stroke = SolidColor(Color.White), strokeLineWidth = 1.8f, strokeLineCap = StrokeCap.Round) {
        moveTo(3f, 11f); lineTo(10.5f, 9.7f)
    }
    path(stroke = SolidColor(Color.White), strokeLineWidth = 1.8f, strokeLineCap = StrokeCap.Round) {
        moveTo(3f, 14f); lineTo(10.5f, 12.7f)
    }
    // Flat (♭): a tall stem with a bowl curving off its lower half to the right.
    path(stroke = SolidColor(Color.White), strokeLineWidth = 1.8f, strokeLineCap = StrokeCap.Round) {
        moveTo(14.5f, 4f); lineTo(14.5f, 18f)
    }
    path(
        stroke = SolidColor(Color.White),
        strokeLineWidth = 1.8f,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
    ) {
        moveTo(14.5f, 11f)
        curveTo(19f, 10f, 18.5f, 15.5f, 14.5f, 17.2f)
    }
}.build()

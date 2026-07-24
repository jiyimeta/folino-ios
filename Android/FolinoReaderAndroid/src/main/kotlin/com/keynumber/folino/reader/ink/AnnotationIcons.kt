package com.keynumber.folino.reader.ink

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * A custom eraser glyph for the annotation toolbar. `material-icons-extended` ships no eraser (only
 * `Backspace`, which reads as "delete", not "erase"), so we draw the standard angled-eraser silhouette
 * ourselves: a rounded block tilted ~45°, with a thin diagonal band near the tip cut out (via
 * [PathFillType.EvenOdd]) so it reads as a two-part eraser rather than a plain lozenge — matching the
 * familiar eraser icon used by Keep / Samsung Notes. Single-tint, so it recolors with the toolbar like
 * any Material icon.
 */
val EraserIcon: ImageVector by lazy {
    ImageVector.Builder(
        name = "Eraser",
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply {
        path(fill = SolidColor(Color.Black), pathFillType = PathFillType.EvenOdd) {
            // Eraser body: the angled block, top-right down to bottom-left.
            moveTo(16.24f, 3.56f)
            lineToRelative(4.95f, 4.94f)
            curveToRelative(0.78f, 0.79f, 0.78f, 2.05f, 0f, 2.84f)
            lineTo(12f, 20.53f)
            curveToRelative(-1.56f, 1.56f, -4.09f, 1.56f, -5.66f, 0f)
            lineTo(2.81f, 17f)
            curveToRelative(-0.78f, -0.79f, -0.78f, -2.05f, 0f, -2.84f)
            lineToRelative(10.6f, -10.6f)
            curveTo(14.2f, 2.78f, 15.46f, 2.78f, 16.24f, 3.56f)
            close()
            // Thin band across the eraser, cut out by even-odd so the two halves read distinctly.
            moveTo(9.52f, 10.28f)
            lineTo(14.47f, 15.23f)
            lineTo(13.77f, 15.93f)
            lineTo(8.82f, 10.98f)
            close()
        }
    }.build()
}

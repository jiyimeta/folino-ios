package com.keynumber.folino.reader.ink

import androidx.ink.brush.Brush
import androidx.ink.brush.BrushFamily
import androidx.ink.brush.SelfOverlap
import androidx.ink.brush.StockBrushes

/** Maps neutral InkStroke tools/colors to androidx.ink brushes, pinning V1 families for stable re-rendering. */
object InkBrushMapping {
    // InkStroke.Tool.rawValue (Domain): pen=0, marker(highlighter)=1, pencil=2, ...
    private fun family(tool: Int): BrushFamily = when (tool) {
        1 -> StockBrushes.highlighter(SelfOverlap.ACCUMULATE, StockBrushes.HighlighterVersion.V1)
        else -> StockBrushes.pressurePen(StockBrushes.PressurePenVersion.V1)
    }

    /** 0xRRGGBBAA (our neutral model) -> @ColorInt 0xAARRGGBB. */
    private fun colorInt(colorRGBA: Long): Int {
        val r = (colorRGBA shr 24) and 0xFF; val g = (colorRGBA shr 16) and 0xFF
        val b = (colorRGBA shr 8) and 0xFF; val a = colorRGBA and 0xFF
        return ((a shl 24) or (r shl 16) or (g shl 8) or b).toInt()
    }

    /** widthSp = document-mm brush size (world unit = document mm); epsilon ~0.1mm keeps strokes crisp to 8x. */
    fun brushFor(tool: Int, colorRGBA: Long, widthSp: Float): Brush =
        Brush.createWithColorIntArgb(
            family = family(tool),
            colorIntArgb = colorInt(colorRGBA),
            size = widthSp.coerceAtLeast(0.01f),
            epsilon = 0.1f,
        )
}

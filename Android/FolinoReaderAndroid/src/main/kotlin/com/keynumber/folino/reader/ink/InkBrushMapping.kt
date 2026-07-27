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

    /**
     * [widthSp] is a brush size in the CALLER's own annotation world units — document mm for a musical
     * surface, raster px for a PDF surface (see `AnnotationSurfaceState.brushWidthWorld`'s doc for the full
     * convention; a caller must already have converted a real mm preference into its own world units
     * before reaching here — this function has no way to know which unit it was handed). `epsilon` (a
     * stroke-simplification tolerance in the SAME units as [widthSp]) is left at a flat `0.1` regardless of
     * that unit, which keeps strokes crisp to 8x zoom for the mm-scale musical case; not re-derived per
     * world unit here, since androidx.ink's own simplification is forgiving of a looser-than-ideal epsilon.
     */
    fun brushFor(tool: Int, colorRGBA: Long, widthSp: Float): Brush =
        Brush.createWithColorIntArgb(
            family = family(tool),
            colorIntArgb = colorInt(colorRGBA),
            size = widthSp.coerceAtLeast(0.01f),
            epsilon = 0.1f,
        )
}

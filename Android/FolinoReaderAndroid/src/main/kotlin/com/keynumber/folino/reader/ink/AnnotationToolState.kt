package com.keynumber.folino.reader.ink

import kotlin.math.abs

/** The annotation tool currently selected in the Reader's annotation toolbar. */
sealed interface AnnotationTool {
    /** Pen tool bound to a palette slot (index into [AnnotationToolbarDefaults.DEFAULT_COLORS]). */
    data class Pen(val colorIndex: Int) : AnnotationTool

    /** Partial eraser — removes ink under the touch path rather than whole strokes. */
    data object Eraser : AnnotationTool
}

/**
 * Selected tool plus the per-tool stroke widths. Each pen palette slot remembers its own width
 * independently (so switching color doesn't reset the width the user picked for that pen), while
 * the eraser has a single width shared across all uses.
 */
data class AnnotationToolState(
    val selected: AnnotationTool = AnnotationTool.Pen(0),
    val penWidths: List<Float> = AnnotationWidths.PEN_DEFAULTS,
    val eraserWidth: Float = AnnotationWidths.ERASER_PRESETS[1],
) {
    /** The width that applies to whichever tool is currently [selected]. */
    val activeWidth: Float
        get() = when (val tool = selected) {
            // Bounds-safe like every other palette-index lookup in this file (see AnnotationToolbar's
            // `penWidths.getOrElse`) — a future restored `penWidths` shorter than the selected
            // `colorIndex` degrades to the same-slot default rather than throwing.
            is AnnotationTool.Pen -> penWidths.getOrElse(tool.colorIndex) {
                AnnotationWidths.PEN_DEFAULTS[tool.colorIndex]
            }
            AnnotationTool.Eraser -> eraserWidth
        }

    /** Returns a copy with [width] applied to the currently [selected] tool only. */
    fun withWidthForSelected(width: Float): AnnotationToolState =
        when (val tool = selected) {
            is AnnotationTool.Pen -> copy(
                penWidths = penWidths.toMutableList().also { it[tool.colorIndex] = width },
            )
            AnnotationTool.Eraser -> copy(eraserWidth = width)
        }
}

/** Fixed stroke-width preset tables for the pen and eraser tools. */
object AnnotationWidths {
    val PEN_PRESETS: List<Float> = listOf(0.6f, 1.2f, 2.0f, 3.2f)
    val ERASER_PRESETS: List<Float> = listOf(2.0f, 4.0f, 8.0f, 14.0f)
    val PEN_DEFAULTS: List<Float> = List(4) { 1.2f }

    /**
     * Index of the [presets] entry nearest to [width] by absolute difference. Never throws for an
     * out-of-range [width] — a persisted width from a future preset table must degrade gracefully
     * to the closest available preset rather than crash.
     */
    fun presetIndex(presets: List<Float>, width: Float): Int =
        presets.indices.minBy { i -> abs(presets[i] - width) }
}

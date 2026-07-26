package com.keynumber.folino.reader.ink

import androidx.compose.runtime.Stable
import androidx.compose.ui.geometry.Offset
import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire

/**
 * Everything a score surface needs to mount the annotation layers, bundled so the three surfaces
 * (vertical / horizontal / page) take one parameter instead of ten identical ones each.
 *
 * All of it is owned by `ReaderScreen` — the erase state machine, the capture pipeline and the
 * wet→dry handoff queue live there because they outlive any single surface (a layout-mode switch
 * swaps the surface but must not restart an in-flight commit). A surface only reads this to decide
 * *where* to draw; it never mutates it.
 *
 * Passed as `null` by surfaces that must not annotate at all — the PiP rendition of
 * [com.keynumber.folino.reader.HorizontalScore], which is a passive mirror with no input.
 */
@Stable
internal class AnnotationSurfaceState(
    /** True while the annotate tool is armed: mounts the wet capture layer over the dry one. */
    val annotationMode: Boolean,
    /** The committed layer, re-anchored and repainted by [AnnotationDryOverlay] on every reflow. */
    val drawings: List<DrawingAnchorWire>,
    /** Bumped on every layout recompute so the dry overlay re-resolves anchors after a reflow. */
    val layoutGeneration: Int,
    /** Active pen color as 0xRRGGBBAA (the neutral wire color model). */
    val colorRGBA: Long,
    /** Active brush size in document mm. */
    val widthMm: Float,
    /** True while the eraser is selected — swaps the wet layer to the partial-erase gesture path. */
    val eraserMode: Boolean,
    val onEraseGesture: (phase: ErasePhase, pathMm: List<Offset>) -> Unit,
    val inkHandoff: AnnotationHandoffQueue<DrawingAnchorWire>,
    val onStrokeCaptured: (stroke: Stroke, onCommitted: (DrawingAnchorWire?) -> Unit) -> Unit,
) {
    companion object {
        /**
         * Wet strokes are always pen (`Domain InkStroke.Tool.pen`). The eraser never *starts* a
         * stroke — it takes the separate erase-gesture path — so no surface ever needs to pass a
         * different tool through to the brush.
         */
        const val WET_STROKE_TOOL = 0
    }
}

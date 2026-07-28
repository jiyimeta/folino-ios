package com.keynumber.folino.reader.ink

import androidx.compose.runtime.Stable
import androidx.compose.ui.geometry.Offset
import androidx.ink.strokes.Stroke
import com.keynumber.folino.reader.DrawingAnchorWire

/**
 * Everything a score surface needs to mount the annotation layers, bundled so the three musical surfaces
 * (vertical / horizontal / page) take one parameter instead of ten identical ones each.
 *
 * The toolbar state (color/width/eraser-mode) is owned by `ReaderScreen`, shared verbatim by every surface
 * — a layout-mode switch must not reset the armed tool. `onEraseGesture` / `onStrokeCaptured` are ALSO
 * built once in `ReaderScreen` for the three musical surfaces, sequencing calls against a musical
 * `scoreHandle`. A PDF surface (Task 11) instead builds its OWN local copy of this whole object — same
 * toolbar fields (color, width, eraser-mode, `inkHandoff`), but its OWN `onEraseGesture`/`onStrokeCaptured`
 * closures routed through the page-anchor JNI path instead — see `PdfVerticalScore`/`PagedPdfScore`'s own
 * `pdfAnnotation` construction. Either way, a surface never MUTATES the instance it's handed; it either
 * reads it as-is (the three musical surfaces) or copies it into a new instance with different closures (the
 * PDF surfaces).
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
    /**
     * Active brush size in THIS surface's annotation "world" units — document mm for the three musical
     * surfaces (their camera's world space genuinely is mm), but raster PX for a PDF surface (`pxPerMM =
     * 1f` there — see `PdfVerticalScore`/`PagedPdfScore`'s own class docs). Deliberately NOT named
     * `widthMm`: that name is what let a real bug (a PDF pen ~5x too thin) pass review, because it claimed
     * a unit that was only true for the surface that happened to write it first. A PDF surface's own
     * `pdfAnnotation` construction converts the shared toolbar's real mm preference into this surface's
     * world units before writing this field (see `PdfVerticalLayout.pxPerPageMm`/`PagedPdfLayout
     * .pxPerPageMm`) — `AnnotationLayers`' brush-building code (and anything else reading this field) can
     * then treat it as "already in world units," full stop, regardless of which surface built it.
     */
    val brushWidthWorld: Float,
    /** True while the eraser is selected — swaps the wet layer to the partial-erase gesture path. */
    val eraserMode: Boolean,
    /**
     * Active eraser DIAMETER, same world-units convention as [brushWidthWorld] (a preset, not a radius —
     * every caller of `EraseGestureController.handle` halves this itself, matching the existing "presets
     * are diameters, `applyErase` wants a radius" convention). Threaded through here (Task 11) so a PDF
     * surface — which has no `toolState` of its own — can build its own eraser gesture handler without a
     * second source of truth for this value.
     */
    val eraserWidthWorld: Float,
    /**
     * [pathWorld] is in the SAME world units as [brushWidthWorld]/[eraserWidthWorld] — whatever
     * `AnnotationWetOverlay`'s `screenToWorld` matrix for THIS surface maps a touch point into (mm for the
     * musical surfaces, raster px for a PDF surface). Not `pathMm`, for the same reason those two fields
     * aren't `*Mm`.
     */
    val onEraseGesture: (phase: ErasePhase, pathWorld: List<Offset>) -> Unit,
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

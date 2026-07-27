package com.keynumber.folino.reader.ink

import android.graphics.Matrix
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import com.keynumber.folino.reader.DrawingAnchorWire

/**
 * Mounts the two annotation layers for one score surface: the DRY layer (committed strokes, always
 * mounted so ink shows even when the tool is put away) and — only while [AnnotationSurfaceState.annotationMode]
 * is armed — the WET capture layer on top.
 *
 * Every surface (vertical / horizontal / page) draws the same layers over a different camera, so the
 * geometry is passed in rather than derived here:
 *
 * - [dryPanOffset] / [dryModifier] place the dry View. The dry View may be document-sized (vertical,
 *   horizontal) or viewport-sized with a shifted origin (page mode) — see [AnnotationDryOverlay]'s
 *   `panOffset` doc.
 * - [wetWorldToScreen] / [wetModifier] place the wet View. This one is ALWAYS viewport-clamped:
 *   androidx.ink draws an in-progress stroke through a front buffer sized to its View, and a
 *   continuous layout is one page as tall (or, horizontally, as wide) as the whole score — well past
 *   SurfaceFlinger's 65536 px render-target limit, where the buffer allocation fails outright, ink
 *   never appears, and the frame the failure lands on can hang the app. Each caller pins its window to
 *   the visible region and folds that same offset into [wetWorldToScreen], so document coordinates
 *   still land exactly where the dry layer painted them.
 */
@Composable
internal fun AnnotationLayers(
    /** See [AnnotationDryOverlay]'s own parameter doc — forwarded straight through. */
    resolveDisplayTransforms: (List<DrawingAnchorWire>) -> ByteArray,
    annotation: AnnotationSurfaceState,
    pxPerMM: Float,
    scale: Float,
    isDrawing: Boolean,
    dryPanOffset: Offset,
    dryModifier: Modifier,
    wetWorldToScreen: Matrix,
    wetModifier: Modifier,
) {
    AnnotationDryOverlay(
        resolveDisplayTransforms = resolveDisplayTransforms,
        drawings = annotation.drawings,
        layoutGeneration = annotation.layoutGeneration,
        pxPerMM = pxPerMM,
        scale = scale,
        isDrawing = isDrawing,
        modifier = dryModifier,
        panOffset = dryPanOffset,
        onRendered = annotation.inkHandoff::onDryRendered,
    )
    if (annotation.annotationMode) {
        // Re-keyed on color + width only — the wet tool is fixed pen (see WET_STROKE_TOOL). While the
        // eraser is selected this still builds a valid brush from its (unused) width, which is never
        // drawn with because the overlay takes the erase-gesture path instead.
        val brush = remember(annotation.colorRGBA, annotation.widthMm) {
            InkBrushMapping.brushFor(
                AnnotationSurfaceState.WET_STROKE_TOOL,
                annotation.colorRGBA,
                widthSp = annotation.widthMm,
            )
        }
        AnnotationWetOverlay(
            worldToScreen = wetWorldToScreen,
            brush = brush,
            // Retain the finished stroke on the wet layer, then commit; the queue removes it once the
            // dry overlay reports having painted the committed drawing.
            onStrokeFinished = { stroke, release ->
                annotation.onStrokeCaptured(stroke, annotation.inkHandoff.retain(release))
            },
            // The surface's own pinch pointerInput (always installed) handles the 2-finger gesture once
            // the wet overlay cancels its stroke and returns `false` from ACTION_POINTER_DOWN — nothing
            // further needed here.
            onTwoFingerGesture = {},
            eraserMode = annotation.eraserMode,
            onEraseGesture = annotation.onEraseGesture,
            modifier = wetModifier,
        )
    }
}

package com.keynumber.folino.reader.editing

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import io.github.jiyimeta.sheetmusic.audio.model.EditCaretFrame

/**
 * The floor a zero-width caret frame is widened to, in document millimetres — ssm's own
 * `LayoutDocument.editingCaretRect(for:in:minimumWidth:)` default, which iOS's `EditingSelectionOverlay` takes by
 * omitting the argument. A caret sitting at the end of a measure resolves to a zero-width column, and without this
 * floor it would draw as nothing at all. Kept here, next to the only caller, rather than duplicated per call site:
 * the callout (Task 8) positions itself from the SELECTION with a different floor (1 mm on iOS), so these are two
 * deliberate values, not one shared constant.
 */
internal const val EDIT_CARET_MINIMUM_WIDTH_MM = 2.0

/**
 * The insertion caret: the translucent column marking the slot the next note goes INTO, drawn over the score while an
 * edit session is open.
 *
 * [rectMm] is ssm's answer for the caret item (`EditGeometry.caretRectMm`) in DOCUMENT millimetres, already narrowed
 * to the item's own staff band by the engine — the band depends on the staff's line count, so it is never measured
 * here. Null draws nothing: no caret item, or an ID a reflow already overtook.
 *
 * The transform mirrors the sibling overlays in the same Box (`PlaybackCursorOverlay`, `LoopHighlightOverlay`,
 * `AbBoundaryMarkersOverlay`): document mm scaled by [pxPerMM] and the live pinch [scale], then translated by
 * [panOffset]. Mount it inside the same `graphicsLayer`-backed node the score content uses so panning and zooming
 * move the caret WITH the score instead of leaving it pinned to the viewport.
 *
 * Deliberately the same accent column the playback head uses, because it means the same thing — "the music is here".
 * iOS made that call in `EditingSelectionOverlay.caretLayer`; a second shape for one idea only asks the reader to
 * learn two marks.
 */
@Composable
fun EditingCaretOverlay(
    rectMm: EditCaretFrame?,
    pxPerMM: Float,
    scale: Float,
    panOffset: Offset,
    color: Color,
    modifier: Modifier = Modifier,
) {
    if (rectMm == null) return
    Canvas(modifier = modifier) {
        drawRect(
            color = color,
            topLeft = Offset(
                (rectMm.xMm * pxPerMM * scale).toFloat() + panOffset.x,
                (rectMm.yMm * pxPerMM * scale).toFloat() + panOffset.y,
            ),
            size = Size(
                (rectMm.widthMm * pxPerMM * scale).toFloat(),
                (rectMm.heightMm * pxPerMM * scale).toFloat(),
            ),
            // Multiply so the bar reads as being BEHIND the notation rather than painted over it — a caret that
            // hides the notehead it sits next to is worse than no caret (spec §7; iOS uses `.blendMode(.multiply)`
            // for exactly this). Painting it UNDER the score instead is not an option: the score surface fills
            // itself with opaque white, so a caret beneath it simply vanishes.
            blendMode = BlendMode.Multiply,
        )
    }
}

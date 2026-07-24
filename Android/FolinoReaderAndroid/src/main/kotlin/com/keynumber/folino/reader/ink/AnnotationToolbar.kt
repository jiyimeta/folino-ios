package com.keynumber.folino.reader.ink

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

/**
 * Annotation toolbar shown in the Reader's bottom bar while annotation mode is active: an eraser
 * button, the four pen color swatches (sized to each pen's current stroke width), undo/redo, and a
 * re-tap width picker for whichever tool is already selected.
 *
 * Selection and width live in [state] ([AnnotationToolState], Task 3); this composable is purely
 * presentational — it reports intent via [onSelect] / [onWidthChange] / [onUndo] / [onRedo] and
 * never mutates anything itself beyond which tool's width picker is open.
 */
@Composable
fun AnnotationToolbar(
    state: AnnotationToolState,
    presetColors: List<Color>,
    canUndo: Boolean,
    canRedo: Boolean,
    onSelect: (AnnotationTool) -> Unit,
    onWidthChange: (Float) -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // The tool whose width picker is currently open (re-tapped while already selected). Null closes
    // the picker. Nested inside each tool's own Box below so the Popup anchors to that tool.
    var pickerFor by remember { mutableStateOf<AnnotationTool?>(null) }
    // If the selection changes out from under an open picker (e.g. a future external selection
    // change), close it rather than leave it open for a tool that's no longer selected.
    LaunchedEffect(state.selected) {
        if (pickerFor != null && pickerFor != state.selected) pickerFor = null
    }

    Surface(tonalElevation = 3.dp, modifier = modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val eraserSelected = state.selected == AnnotationTool.Eraser
            // Fixed 48dp slot (the Material minimum touch target) regardless of the eraser's own size
            // indicator dot — kept the same shape as the pen swatches below for a uniform tap-target
            // size across the whole toolbar, even though IconButton already reserves ≥48dp on its own.
            Box(modifier = Modifier.size(TAP_TARGET_SIZE), contentAlignment = Alignment.Center) {
                IconButton(
                    onClick = {
                        if (eraserSelected) pickerFor = AnnotationTool.Eraser else onSelect(AnnotationTool.Eraser)
                    },
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.Backspace,
                        contentDescription = "Eraser",
                        tint = if (eraserSelected) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
                if (eraserSelected) {
                    // Small size indicator dot (not a full swatch — the eraser has no color), scaled off
                    // the same preset table as the width picker so it visually tracks the active preset.
                    val diameter = SWATCH_DIAMETERS_DP[
                        AnnotationWidths.presetIndex(AnnotationWidths.ERASER_PRESETS, state.eraserWidth),
                    ].dp
                    Box(
                        Modifier
                            .align(Alignment.BottomEnd)
                            .padding(end = 2.dp, bottom = 2.dp)
                            .size((diameter / 3).coerceAtLeast(4.dp))
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.onSurface),
                    )
                }
                if (pickerFor == AnnotationTool.Eraser) {
                    AnnotationWidthPicker(
                        presets = AnnotationWidths.ERASER_PRESETS,
                        currentWidth = state.eraserWidth,
                        color = null,
                        onPick = { width ->
                            onWidthChange(width)
                            pickerFor = null
                        },
                        onDismiss = { pickerFor = null },
                    )
                }
            }

            presetColors.forEachIndexed { index, c ->
                val tool = AnnotationTool.Pen(index)
                val selected = state.selected == tool
                // Bounds-safe: a future restored `penWidths` shorter than `presetColors` degrades to the
                // 1.2 default rather than throwing.
                val penWidth = state.penWidths.getOrElse(index) { AnnotationWidths.PEN_PRESETS[1] }
                val diameter = SWATCH_DIAMETERS_DP[
                    AnnotationWidths.presetIndex(AnnotationWidths.PEN_PRESETS, penWidth),
                ].dp

                Box {
                    // Fixed 48dp tap-target slot (the Material minimum), independent of the swatch's own
                    // width-driven diameter — `.clickable` sits on the slot, not the visual circle, so the
                    // thinnest 14dp swatch still has a full-size touch target. The ring + swatch are
                    // centered inside it, so a width change never nudges the slot's own position/size.
                    Box(
                        modifier = Modifier
                            .size(TAP_TARGET_SIZE)
                            .clickable { if (selected) pickerFor = tool else onSelect(tool) },
                        contentAlignment = Alignment.Center,
                    ) {
                        // The ring lives on a slightly larger container than the swatch itself, so drawing
                        // it never changes the swatch's own diameter (which is the width indicator).
                        Box(
                            modifier = Modifier
                                .size(diameter + RING_PADDING * 2)
                                .then(
                                    if (selected) {
                                        Modifier.border(2.dp, MaterialTheme.colorScheme.outline, CircleShape)
                                    } else {
                                        Modifier
                                    },
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Box(Modifier.size(diameter).clip(CircleShape).background(c))
                        }
                    }
                    if (pickerFor == tool) {
                        AnnotationWidthPicker(
                            presets = AnnotationWidths.PEN_PRESETS,
                            currentWidth = penWidth,
                            color = c,
                            onPick = { width ->
                                onWidthChange(width)
                                pickerFor = null
                            },
                            onDismiss = { pickerFor = null },
                        )
                    }
                }
            }

            Box(Modifier.weight(1f))

            IconButton(onClick = onUndo, enabled = canUndo) {
                Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = "Undo")
            }
            IconButton(onClick = onRedo, enabled = canRedo) {
                Icon(Icons.AutoMirrored.Filled.Redo, contentDescription = "Redo")
            }
        }
    }
}

/** Preset swatches for [AnnotationToolbar] — a fixed MVP palette; a custom color picker is future UI work. */
object AnnotationToolbarDefaults {
    val DEFAULT_COLORS: List<Color> = listOf(
        Color.Black,
        Color.Red,
        Color(0xFF1565C0), // blue
        Color(0xFF2E7D32), // green
    )
}

/**
 * Swatch diameters (dp) indexed by preset position — shared with [AnnotationWidthPicker] so the
 * picker's circles read as the same size scale as the toolbar's. `internal` rather than private:
 * both files live in this package but are separate compilation units, and this constant is not part
 * of the module's public API.
 */
internal val SWATCH_DIAMETERS_DP = listOf(14, 20, 26, 32)

/**
 * Extra room the selection ring occupies around a swatch, on each side. `internal` — shared with
 * [AnnotationWidthPicker], which draws the same ring around its own preset circles.
 */
internal val RING_PADDING = 4.dp

/**
 * The Material minimum touch target. Every tappable swatch/eraser slot (toolbar) and preset circle
 * (width picker) is fixed at this size regardless of its visual diameter, so the smallest 14dp swatch
 * still has a full-size tap target and a width change never nudges a neighbouring slot's position.
 * `internal` — shared with [AnnotationWidthPicker].
 */
internal val TAP_TARGET_SIZE = 48.dp

@Preview(name = "Toolbar — pen selected", showBackground = true)
@Composable
private fun AnnotationToolbarPenPreview() {
    AnnotationToolbar(
        state = AnnotationToolState(
            selected = AnnotationTool.Pen(2),
            penWidths = listOf(0.6f, 1.2f, 2.0f, 3.2f),
        ),
        presetColors = AnnotationToolbarDefaults.DEFAULT_COLORS,
        canUndo = true,
        canRedo = false,
        onSelect = {},
        onWidthChange = {},
        onUndo = {},
        onRedo = {},
    )
}

@Preview(name = "Toolbar — eraser selected", showBackground = true)
@Composable
private fun AnnotationToolbarEraserPreview() {
    AnnotationToolbar(
        state = AnnotationToolState(
            selected = AnnotationTool.Eraser,
            eraserWidth = AnnotationWidths.ERASER_PRESETS[2],
        ),
        presetColors = AnnotationToolbarDefaults.DEFAULT_COLORS,
        canUndo = true,
        canRedo = true,
        onSelect = {},
        onWidthChange = {},
        onUndo = {},
        onRedo = {},
    )
}

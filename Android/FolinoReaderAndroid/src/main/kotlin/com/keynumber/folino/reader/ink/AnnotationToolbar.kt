package com.keynumber.folino.reader.ink

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Annotation toolbar shown in the Reader's bottom bar while annotation mode is active: an eraser
 * button, the four pen color swatches (sized to each pen's current stroke width), undo/redo, and a
 * re-tap width picker for whichever tool is already selected.
 *
 * Selection and width live in [state] ([AnnotationToolState]); this composable is purely
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
            // Fixed 48dp tap-target slot, identical to the pen swatches so the whole row shares one
            // visual language. The eraser is a width swatch too — but in a neutral tone (it has no ink
            // color) and badged with the eraser glyph at the ring's bottom-right so it still reads as
            // "the eraser" while its dot tracks the current erase width.
            Box(
                modifier = Modifier
                    .size(TAP_TARGET_SIZE)
                    .clickable {
                        if (eraserSelected) pickerFor = AnnotationTool.Eraser else onSelect(AnnotationTool.Eraser)
                    },
                contentAlignment = Alignment.Center,
            ) {
                WidthSwatch(
                    color = null,
                    width = state.eraserWidth,
                    selected = eraserSelected,
                ) {
                    Box(
                        Modifier
                            .align(Alignment.BottomEnd)
                            .size(16.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surface),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            EraserIcon,
                            contentDescription = "Eraser",
                            modifier = Modifier.size(11.dp),
                            tint = MaterialTheme.colorScheme.onSurface,
                        )
                    }
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

                Box {
                    // Fixed 48dp tap-target slot (the Material minimum), independent of the swatch's own
                    // width-driven diameter — `.clickable` sits on the slot, not the visual circle.
                    Box(
                        modifier = Modifier
                            .size(TAP_TARGET_SIZE)
                            .clickable { if (selected) pickerFor = tool else onSelect(tool) },
                        contentAlignment = Alignment.Center,
                    ) {
                        // A constant-size ring (the "well") holds a colored dot whose diameter is
                        // proportional to the pen's ACTUAL stroke width — so every pen sits in the same
                        // footprint while the dot inside shows how thick that pen draws. The selected pen's
                        // ring thickens and takes the primary color.
                        WidthSwatch(color = c, width = penWidth, selected = selected)
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
 * A width swatch shared by the toolbar and [AnnotationWidthPicker]. A constant-size ring (the "well",
 * [SWATCH_CONTAINER_DP]) holding a dot whose diameter is the TRUE stroke [width] ([dotDiameter] — the
 * same dp-per-mm scale for every tool, so a thick tool genuinely shows a bigger dot than a thin one
 * rather than each filling its own well). [selected] thickens the ring and switches it to the primary
 * color. [badge] draws an optional decoration (the eraser glyph) hanging at the ring's bottom-right
 * corner — it sits outside the clipped well so it is never masked away.
 *
 * Two visual modes keyed off [color]:
 * - A pen (non-null [color]): a white interior with a light [SWATCH_WASH_ALPHA] wash of the ink color
 *   over it — so the color reads even when the dot is tiny — topped by a solid ink dot.
 * - The eraser (null [color]): a plain white interior and a white, outlined dot (the eraser has no ink
 *   color of its own, so its footprint reads as a ring rather than a filled disc).
 */
@Composable
internal fun WidthSwatch(
    color: Color?,
    width: Float,
    selected: Boolean,
    modifier: Modifier = Modifier,
    badge: (@Composable BoxScope.() -> Unit)? = null,
) {
    Box(modifier.size(SWATCH_CONTAINER_DP), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .matchParentSize()
                .clip(CircleShape)
                .background(Color.White)
                .then(if (color != null) Modifier.background(color.copy(alpha = SWATCH_WASH_ALPHA)) else Modifier)
                .border(
                    width = if (selected) 2.5.dp else 1.dp,
                    color = if (selected) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.outlineVariant
                    },
                    shape = CircleShape,
                ),
        )
        if (color != null) {
            Box(Modifier.size(dotDiameter(width)).clip(CircleShape).background(color))
        } else {
            Box(
                Modifier
                    .size(dotDiameter(width))
                    .clip(CircleShape)
                    .background(Color.White)
                    .border(1.dp, MaterialTheme.colorScheme.outline, CircleShape),
            )
        }
        badge?.invoke(this)
    }
}

/**
 * True-to-width dot diameter: [width] document-mm at [DOT_DP_PER_MM] dp/mm, capped at [SWATCH_DOT_MAX_DP]
 * so it always fits inside the well. The scale is shared across tools, so a 3.2mm pen and a 14mm eraser
 * show honestly different dots instead of each being normalized to fill its own ring.
 */
internal fun dotDiameter(width: Float): Dp = (width * DOT_DP_PER_MM).dp.coerceAtMost(SWATCH_DOT_MAX_DP)

/** dp per document-mm for a width dot. Tuned so the largest eraser preset (14mm) about fills the well. */
internal const val DOT_DP_PER_MM = 2.0f

/** Opacity of the ink-color wash over a pen swatch's white interior, so the color reads at a glance. */
private const val SWATCH_WASH_ALPHA = 0.2f

/** The constant ring/well every swatch and preset circle is drawn in, regardless of its dot's size. */
internal val SWATCH_CONTAINER_DP = 34.dp

/** Largest width-dot, so even an oversized stored width can't overflow the [SWATCH_CONTAINER_DP] ring. */
private val SWATCH_DOT_MAX_DP = 28.dp

/**
 * The Material minimum touch target. Every tappable swatch/eraser slot (toolbar) and preset circle
 * (width picker) is fixed at this size regardless of its visual diameter, so the swatch still has a
 * full-size tap target and a width change never nudges a neighbouring slot's position. `internal` —
 * shared with [AnnotationWidthPicker].
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

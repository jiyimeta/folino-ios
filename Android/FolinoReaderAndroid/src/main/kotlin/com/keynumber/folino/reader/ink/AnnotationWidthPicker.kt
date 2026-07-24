package com.keynumber.folino.reader.ink

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties

/**
 * Re-tap width picker for [AnnotationToolbar]: shown when the user taps a tool that is already
 * selected, offering that tool's fixed [presets] as a row of [WidthSwatch] circles — each a constant
 * ring holding a dot proportional to that preset's actual width — with the preset nearest [currentWidth]
 * ringed. Tapping a preset applies it via [onPick]; tapping outside the
 * popup (or the system back gesture) fires [onDismiss] — `PopupProperties(focusable = true)` gives it
 * its own focus scope so outside taps are observed as a dismiss rather than passing through to the
 * toolbar underneath.
 *
 * Composed as a direct child of the anchor tool's own `Box` in [AnnotationToolbar], so the [Popup]
 * positions itself relative to that tool rather than the toolbar as a whole.
 *
 * [color] is the pen's ink color for a [AnnotationTool.Pen]; pass `null` for [AnnotationTool.Eraser] so
 * each preset renders in the eraser's white-well / outlined-dot style (the eraser has no color of its own).
 */
@Composable
internal fun AnnotationWidthPicker(
    presets: List<Float>,
    currentWidth: Float,
    color: Color?,
    onPick: (Float) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentIndex = AnnotationWidths.presetIndex(presets, currentWidth)
    val verticalGapPx = with(LocalDensity.current) { 8.dp.roundToPx() }

    Popup(
        alignment = Alignment.BottomCenter,
        offset = IntOffset(0, verticalGapPx),
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true),
    ) {
        Surface(
            tonalElevation = 6.dp,
            shadowElevation = 6.dp,
            shape = MaterialTheme.shapes.medium,
            modifier = modifier,
        ) {
            Row(
                Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                presets.forEachIndexed { index, preset ->
                    // Fixed 48dp tap-target slot, same shape as the toolbar's swatches: `.clickable` sits
                    // on the slot (not the visual circle), so even the smallest preset has a full-size
                    // touch target and its neighbours never shift when a preset is picked. Each preset
                    // renders as the same constant ring with a dot proportional to its actual width.
                    Box(
                        modifier = Modifier
                            .size(TAP_TARGET_SIZE)
                            .clickable { onPick(preset) },
                        contentAlignment = Alignment.Center,
                    ) {
                        WidthSwatch(
                            color = color,
                            width = preset,
                            selected = index == currentIndex,
                        )
                    }
                }
            }
        }
    }
}

@Preview(name = "Width picker — open", showBackground = true)
@Composable
private fun AnnotationWidthPickerPreview() {
    Box(Modifier.size(200.dp, 120.dp)) {
        AnnotationWidthPicker(
            presets = AnnotationWidths.PEN_PRESETS,
            currentWidth = AnnotationWidths.PEN_PRESETS[1],
            color = Color.Red,
            onPick = {},
            onDismiss = {},
        )
    }
}

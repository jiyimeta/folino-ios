package com.keynumber.folino.reader.ink

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Minimal annotation toolbar shown in the Reader's bottom bar while annotation mode is active: pen
 * (implicit — the only tool wired for this MVP) plus a row of preset color swatches. Eraser
 * tap-to-delete, highlighter, a stroke-width slider, and undo/redo are deferred to a later UI
 * iteration (Sub-plan E scope) — this only covers pen drawing + color selection.
 */
@Composable
fun AnnotationToolbar(
    color: Color,
    presetColors: List<Color>,
    onColorChange: (Color) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(tonalElevation = 3.dp, modifier = modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            presetColors.forEach { c ->
                Surface(
                    color = c,
                    shape = MaterialTheme.shapes.small,
                    border = if (c == color) ButtonDefaults.outlinedButtonBorder(enabled = true) else null,
                    modifier = Modifier.size(30.dp),
                ) {
                    Box(Modifier.fillMaxSize().clickable { onColorChange(c) })
                }
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

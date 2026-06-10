package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource

@Composable
private fun PlaylistContinuationMode.label(): String = stringResource(
    when (this) {
        PlaylistContinuationMode.OFF -> R.string.reader_continuation_off
        PlaylistContinuationMode.PLAY_THROUGH -> R.string.reader_continuation_play_through
        PlaylistContinuationMode.LOOP_PLAYLIST -> R.string.reader_continuation_loop_playlist
    },
)

/** Minimal menu-style continuation picker (off / continuous / repeat-all). Restyleable; logic-free. */
@Composable
fun PlaylistContinuationPicker(
    selected: PlaylistContinuationMode,
    enabled: Boolean,
    onSelect: (PlaylistContinuationMode) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val tint =
        if (enabled) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { expanded = true }, enabled = enabled) {
            Text(selected.label(), color = tint)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = tint)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (mode in PlaylistContinuationMode.entries) {
                DropdownMenuItem(
                    text = { Text(mode.label()) },
                    onClick = { onSelect(mode); expanded = false },
                )
            }
        }
    }
}

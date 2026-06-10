package com.keynumber.folino.reader

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

private fun RepeatMode.iconVector(): ImageVector = when (this) {
    RepeatMode.OFF -> Icons.Filled.Close
    RepeatMode.LOOP_ALL -> Icons.Filled.RepeatOne
    RepeatMode.AB_LOOP -> Icons.Filled.Repeat // distinguished by the "A–B Loop" label
}

@Composable
private fun RepeatMode.label(): String = stringResource(
    when (this) {
        RepeatMode.OFF -> R.string.reader_repeat_off
        RepeatMode.LOOP_ALL -> R.string.reader_repeat_loop_all
        RepeatMode.AB_LOOP -> R.string.reader_repeat_ab
    },
)

/** Menu-style repeat-mode picker mirroring the iOS Menu+Picker (icon + label + dropdown chevron). */
@Composable
fun RepeatModePicker(selected: RepeatMode, enabled: Boolean, onSelect: (RepeatMode) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val tint =
        if (enabled) MaterialTheme.colorScheme.onSurfaceVariant
        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { expanded = true }, enabled = enabled) {
            Icon(selected.iconVector(), contentDescription = null, modifier = Modifier.size(20.dp), tint = tint)
            Text(selected.label(), color = tint)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = tint)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (mode in RepeatMode.entries) {
                DropdownMenuItem(
                    text = { Text(mode.label()) },
                    leadingIcon = { Icon(mode.iconVector(), contentDescription = null) },
                    onClick = { onSelect(mode); expanded = false },
                )
            }
        }
    }
}

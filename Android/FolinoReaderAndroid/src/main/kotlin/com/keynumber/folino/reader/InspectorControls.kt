package com.keynumber.folino.reader

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.ui.InspectorRow

/**
 * Per-score transpose row. Shared between the playback and display inspectors.
 *
 * Mirrors the iOS TransposeRow inspector design:
 * - Optional leading vertical-arrows icon (shown in the playback inspector, hidden in the
 *   display inspector which has no leading icons).
 * - "Transpose" label.
 * - Signed monospaced readout ("+3" / "0" / "-2") that is a tap-to-reset button.
 * - A compact ± stepper clamped to −7..7 semitones.
 */
@Composable
internal fun TransposeRow(
    semitones: Int,
    enabled: Boolean,
    onChange: (Int) -> Unit,
    showLeadingIcon: Boolean = true,
) {
    val signedReadout = if (semitones > 0) "+$semitones" else "$semitones"
    InspectorRow(
        label = stringResource(R.string.reader_inspector_transpose),
        leadingIcon = if (showLeadingIcon) Icons.Default.SwapVert else null,
        leadingIconTint = if (showLeadingIcon) MaterialTheme.colorScheme.primary else null,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Tap-to-reset readout: tapping the signed value resets transpose to 0 (iOS parity).
            Text(
                text = signedReadout,
                modifier = Modifier
                    .clickable(enabled = enabled) { onChange(0) }
                    .padding(horizontal = 4.dp),
                style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            )
            // ± stepper: two compact IconButtons mirroring iOS's Stepper(value, in: -7...7).
            IconButton(
                onClick = { onChange((semitones - 1).coerceAtLeast(-7)) },
                enabled = enabled && semitones > -7,
                modifier = Modifier.size(32.dp),
            ) {
                Icon(Icons.Default.Remove, contentDescription = "Transpose down", modifier = Modifier.size(16.dp))
            }
            IconButton(
                onClick = { onChange((semitones + 1).coerceAtMost(7)) },
                enabled = enabled && semitones < 7,
                modifier = Modifier.size(32.dp),
            ) {
                Icon(Icons.Default.Add, contentDescription = "Transpose up", modifier = Modifier.size(16.dp))
            }
        }
    }
}

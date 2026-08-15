package com.keynumber.folino.reader.editing

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NavigateBefore
import androidx.compose.material.icons.filled.NavigateNext
import androidx.compose.material.icons.filled.Piano
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.R

/** How many voices the pad's voice selector offers — 1 through [VOICE_COUNT], matching the shared engine's
 * fixed voice count (iOS's `EditorVoicePicker` offers the same range). */
private const val VOICE_COUNT = 4

/**
 * A fixed row above the transport, shown for the duration of an edit session: the voice selector (1–4),
 * the pad toggle, and the ← / → selection steppers — Android's own placement for the same three controls
 * iOS keeps in its navigation bar (spec §7). The steppers sit HERE rather than inside the pad on
 * purpose: stepping the selection is navigation, not writing, so it belongs with the transport, and
 * keeping it out of the pad means it stays reachable — and keeps its place in this bar — even while the
 * pad is closed.
 *
 * [activeVoice] is the zero-indexed voice the engine is currently writing into ([EditUiState.activeVoice]
 * [com.keynumber.folino.editor.EditUiState.activeVoice]); the row displays it as 1-based, matching iOS's
 * `viewModel.activeVoice + 1`. [onSetVoice] is called with the same zero-indexed value.
 *
 * [steppersEnabled] mirrors iOS's `navigationPill.disabled(viewModel.isPlaybackActive)`: stepping the
 * selection while the score is playing would fight the moving playback cursor for the same caret, so the
 * caller wires this to `!isPlaying`. The voice selector and pad toggle are not gated by playback — only
 * navigating the selection is.
 */
@Composable
fun EditingBottomBar(
    activeVoice: Int,
    isPadVisible: Boolean,
    onSetVoice: (Int) -> Unit,
    onTogglePad: () -> Unit,
    onSelectPreviousElement: () -> Unit,
    onSelectNextElement: () -> Unit,
    modifier: Modifier = Modifier,
    steppersEnabled: Boolean = true,
) {
    Surface(tonalElevation = 3.dp, modifier = modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                for (voice in 0 until VOICE_COUNT) {
                    val label = stringResource(R.string.reader_editing_voice, voice + 1)
                    FilledIconToggleButton(
                        checked = activeVoice == voice,
                        onCheckedChange = { onSetVoice(voice) },
                    ) {
                        Text("${voice + 1}", fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            FilledIconToggleButton(checked = isPadVisible, onCheckedChange = { onTogglePad() }) {
                Icon(Icons.Filled.Piano, contentDescription = stringResource(R.string.reader_editing_pad))
            }

            Box(Modifier.weight(1f))

            IconButton(onClick = onSelectPreviousElement, enabled = steppersEnabled) {
                Icon(Icons.Filled.NavigateBefore, contentDescription = "Previous note")
            }
            IconButton(onClick = onSelectNextElement, enabled = steppersEnabled) {
                Icon(Icons.Filled.NavigateNext, contentDescription = "Next note")
            }
        }
    }
}

@Preview(name = "Editing bottom bar", showBackground = true)
@Composable
private fun EditingBottomBarPreview() {
    EditingBottomBar(
        activeVoice = 0,
        isPadVisible = false,
        onSetVoice = {},
        onTogglePad = {},
        onSelectPreviousElement = {},
        onSelectNextElement = {},
    )
}

@Preview(name = "Editing bottom bar — pad open, voice 3", showBackground = true)
@Composable
private fun EditingBottomBarPadOpenPreview() {
    EditingBottomBar(
        activeVoice = 2,
        isPadVisible = true,
        onSetVoice = {},
        onTogglePad = {},
        onSelectPreviousElement = {},
        onSelectNextElement = {},
        steppersEnabled = false,
    )
}

package com.keynumber.folino.reader.editing

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NavigateBefore
import androidx.compose.material.icons.filled.NavigateNext
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.keynumber.folino.reader.R

/**
 * The ← / → selection steppers, as their own small pill at the bottom-left of the editing surface.
 *
 * **Not on the pad.** They were, and before that they were in a fixed row of their own; both were wrong for the
 * same reason iOS states from its side: stepping the caret is NAVIGATION, not writing, so it belongs beside the
 * transport rather than among the keys that change the score. Keeping it out of the pad also means it stays put
 * when the pad is tucked away — the one control you still want when the keyboard is parked at the edge is the one
 * that moves where the next note would go.
 *
 * Gated on playback only, deliberately NOT on `hasEditTarget` — matching iOS's own pill, which carries just
 * `.disabled(viewModel.isPlaybackActive)`. Stepping with nothing selected is a no-op in the shared core rather than
 * an error, and greying the pill out for it would say "this is broken" about a control that is simply idle.
 */
@Composable
fun EditingStepperPill(
    enabled: Boolean,
    onSelectPreviousElement: () -> Unit,
    onSelectNextElement: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        tonalElevation = 3.dp,
        shadowElevation = 3.dp,
        shape = RoundedCornerShape(24.dp),
        modifier = modifier,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onSelectPreviousElement, enabled = enabled) {
                Icon(
                    Icons.Filled.NavigateBefore,
                    contentDescription = stringResource(R.string.reader_editing_previous_element),
                )
            }
            IconButton(onClick = onSelectNextElement, enabled = enabled) {
                Icon(
                    Icons.Filled.NavigateNext,
                    contentDescription = stringResource(R.string.reader_editing_next_element),
                )
            }
        }
    }
}

@Preview(name = "Editing stepper pill", showBackground = true)
@Composable
private fun EditingStepperPillPreview() {
    EditingStepperPill(enabled = true, onSelectPreviousElement = {}, onSelectNextElement = {})
}

@Preview(name = "Editing stepper pill — playing", showBackground = true)
@Composable
private fun EditingStepperPillDisabledPreview() {
    EditingStepperPill(enabled = false, onSelectPreviousElement = {}, onSelectNextElement = {})
}

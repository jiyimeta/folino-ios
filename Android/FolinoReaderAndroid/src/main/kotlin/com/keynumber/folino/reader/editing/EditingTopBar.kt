package com.keynumber.folino.reader.editing

import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import com.keynumber.folino.editor.EditAvailability
import com.keynumber.folino.reader.R

/**
 * The Reader's app-bar actions while an edit session is open — undo, redo and a `Done` that ends the
 * session — REPLACING the reading actions (share, edit info, playback controls, display settings,
 * annotate) rather than joining them, mirroring how [ReaderTopBar][com.keynumber.folino.reader.ReaderTopBar]
 * already swaps content for a contextual mode. Mounted inside its `actions` slot; the back arrow's own
 * swap (ending the session instead of navigating away) lives in that caller, since it also owns the
 * `BackHandler` for the system back gesture.
 *
 * [canUndo] / [canRedo] gate the two icon buttons directly off [EditUiState][com.keynumber.folino.editor.EditUiState]
 * — no local state, this composable is purely presentational.
 */
@Composable
fun EditingTopBarActions(
    canUndo: Boolean,
    canRedo: Boolean,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onEndEditing: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onUndo, enabled = canUndo) {
            Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = stringResource(R.string.reader_editing_undo))
        }
        IconButton(onClick = onRedo, enabled = canRedo) {
            Icon(Icons.AutoMirrored.Filled.Redo, contentDescription = stringResource(R.string.reader_editing_redo))
        }
        TextButton(onClick = onEndEditing) {
            Text(stringResource(R.string.reader_editing_done), fontWeight = FontWeight.SemiBold)
        }
    }
}

/**
 * The two [EditAvailability] failure cases a user can actually hit by tapping "Edit notes" — a version-skew
 * refusal (Folino's compiled-in engine stamp doesn't match the `.so` behind the score handle; spec §8.1) and a
 * diverged-session refusal (a resync couldn't reconcile the two copies of the score; spec §8.3) — each get their
 * own body text rather than one collapsed "editing unavailable" message, so a user hitting the rare divergence
 * case isn't told the same thing as one hitting a genuine build mismatch. [AVAILABLE] and
 * [UNAVAILABLE_NO_SCORE][EditAvailability.UNAVAILABLE_NO_SCORE] never reach here: the former isn't a failure, and
 * the latter is the PDF-refusal case the composition root gates before `begin()` is ever called (a PDF has no
 * "Edit notes" action to tap in the first place), so this dialog has no third body to show.
 */
@Composable
fun EditingUnavailableDialog(reason: EditAvailability, onDismiss: () -> Unit) {
    val bodyRes = when (reason) {
        EditAvailability.UNAVAILABLE_VERSION_SKEW -> R.string.reader_editing_unavailable_version
        EditAvailability.UNAVAILABLE_DIVERGED -> R.string.reader_editing_unavailable_diverged
        EditAvailability.AVAILABLE, EditAvailability.UNAVAILABLE_NO_SCORE -> return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        text = { Text(stringResource(bodyRes)) },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.ok)) }
        },
    )
}

@Preview(name = "Editing top-bar actions", showBackground = true)
@Composable
private fun EditingTopBarActionsPreview() {
    EditingTopBarActions(canUndo = true, canRedo = false, onUndo = {}, onRedo = {}, onEndEditing = {})
}

@Preview(name = "Editing unavailable — version skew", showBackground = true)
@Composable
private fun EditingUnavailableVersionPreview() {
    EditingUnavailableDialog(reason = EditAvailability.UNAVAILABLE_VERSION_SKEW, onDismiss = {})
}

@Preview(name = "Editing unavailable — diverged", showBackground = true)
@Composable
private fun EditingUnavailableDivergedPreview() {
    EditingUnavailableDialog(reason = EditAvailability.UNAVAILABLE_DIVERGED, onDismiss = {})
}

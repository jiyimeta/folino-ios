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
 * Whether an unavailable-refusal dialog should show right now, and for which reason — pure, so it is
 * unit-testable without a Compose harness (this module has none; see `EditSessionControllerTest`'s own
 * host tests for the availability enum's producing side).
 *
 * The caller MUST NOT rely on [availability] alone changing value to decide when to re-derive this: a
 * repeat of the SAME refusal (tap "Edit notes", dismiss, tap again, get the same version-skew result)
 * leaves [EditUiState.availability][com.keynumber.folino.editor.EditUiState.availability] byte-identical
 * to what it already was — `MutableStateFlow` conflates equal emissions at the source, so a
 * `LaunchedEffect` keyed only on `editing.availability` / `editing.isEditing` never re-runs for the second
 * attempt. The fix is at the CALL SITE (key the effect on a per-tap counter too, so the effect re-runs on
 * every "Edit notes" tap regardless of whether the resulting value differs from before) — this function
 * only answers "given the current values, what should show", which is correct to call on every re-run,
 * repeat or not.
 */
internal fun editingUnavailableReasonFor(availability: EditAvailability, isEditing: Boolean): EditAvailability? {
    if (isEditing) return null
    return when (availability) {
        EditAvailability.UNAVAILABLE_VERSION_SKEW, EditAvailability.UNAVAILABLE_DIVERGED -> availability
        EditAvailability.AVAILABLE, EditAvailability.UNAVAILABLE_NO_SCORE -> null
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
 *
 * That second claim is now enforced rather than assumed (SP4 Task 9):
 * [ReaderTopBar][com.keynumber.folino.reader.ReaderTopBar] takes a `canEdit` flag and the Reader passes
 * `state is ReaderState.Ready`, so the action is absent for a PDF, for a load error and while loading — every state
 * in which `open()` could answer `NO_HANDLE` or `SCORE_UNREADABLE`. Silence for that case is therefore correct, not
 * a missing message: there is no tap that can reach it, and a body written for it would be dead copy in five
 * languages. If a future caller starts offering the action without that gate, this is the comment it invalidates.
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

/**
 * The refusal for the one case that is neither an [EditAvailability] nor a reason to hide the action: the reader is
 * in page or horizontal layout, where the score surface has no hit-test, caret or tint wiring of its own (see the
 * `PARITY(android)` marker at `ReaderScreen`'s `HorizontalScore` call site).
 *
 * A dialog rather than a hidden action, unlike the PDF case: "page" is the default layout preference, so hiding the
 * action there would leave most users with no evidence the feature exists at all. And a dialog rather than an inert
 * tap, because the user can act on this — the message names the layout that works, which is one row away in display
 * settings. Separate from [EditingUnavailableDialog] because this is the Reader's own precondition, not something
 * the session reported: no `begin()` call is made, so there is no `EditAvailability` to carry it.
 */
@Composable
fun EditingLayoutModeDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        text = { Text(stringResource(R.string.reader_editing_unavailable_layout_mode)) },
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

@Preview(name = "Editing unavailable — layout mode", showBackground = true)
@Composable
private fun EditingLayoutModePreview() {
    EditingLayoutModeDialog(onDismiss = {})
}

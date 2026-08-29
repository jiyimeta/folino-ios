package com.keynumber.folino.reader.editing

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Piano
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.keynumber.folino.editor.EditAvailability
import com.keynumber.folino.reader.R

/** How many voices the voice picker offers — 1 through [VOICE_COUNT], matching the shared engine's fixed voice
 * count (iOS's `EditorVoicePicker` offers the same range, for the same reason: a MuseScore staff carries up to
 * four voices). */
private const val VOICE_COUNT = 4

/**
 * The Reader's app-bar actions while an edit session is open — undo, redo, the voice picker, the note-pad
 * toggle and a `Done` that ends the session — REPLACING the reading actions (share, edit info, playback
 * controls, display settings, annotate) rather than joining them, mirroring how
 * [ReaderTopBar][com.keynumber.folino.reader.ReaderTopBar] already swaps content for a contextual mode. Mounted
 * inside its `actions` slot; the back arrow's own swap (ending the session instead of navigating away) lives in
 * that caller, since it also owns the `BackHandler` for the system back gesture.
 *
 * **The voice picker and the pad toggle used to live in a fixed row above the transport (`EditingBottomBar`).**
 * That row is gone: it cost the score a band of screen for the whole session to hold three controls, and it
 * spelled voice as four always-visible buttons — a quarter of the row spent on a choice that is made rarely and
 * is almost always 1. Both belong to the SESSION rather than to what is being written, and the app bar is where
 * Android puts a session's own controls; iOS reaches the same place from its side (`EditorTopBarView` carries the
 * voice picker in its control tier, and its pad is dismissed and recalled in place). The ← / → steppers that
 * shared that row moved the other way, onto the pad itself — see `EditingPad`.
 *
 * The voice picker is ONE control that shows the current voice and opens a menu of the four — the same shape
 * iOS settled on in `EditorVoicePicker` (a menu, not the segmented control it used to be), because four
 * permanent buttons crowd out the title on a phone and buy nothing.
 *
 * [canUndo] / [canRedo] / [activeVoice] / [isPadVisible] come straight from
 * [EditUiState][com.keynumber.folino.editor.EditUiState] — the only local state here is whether the voice menu
 * is open, which nothing outside this row has any use for. [activeVoice] is zero-indexed and displayed 1-based,
 * matching iOS's `viewModel.activeVoice + 1`; [onSetVoice] is called with the zero-indexed value.
 */
@Composable
fun EditingTopBarActions(
    canUndo: Boolean,
    canRedo: Boolean,
    activeVoice: Int,
    isPadVisible: Boolean,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onSetVoice: (Int) -> Unit,
    onTogglePad: () -> Unit,
    onEndEditing: () -> Unit,
    canRevertToOriginal: Boolean,
    onRevertToOriginal: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onUndo, enabled = canUndo) {
            Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = stringResource(R.string.reader_editing_undo))
        }
        IconButton(onClick = onRedo, enabled = canRedo) {
            Icon(Icons.AutoMirrored.Filled.Redo, contentDescription = stringResource(R.string.reader_editing_redo))
        }
        VoicePicker(activeVoice = activeVoice, onSetVoice = onSetVoice)
        FilledIconToggleButton(checked = isPadVisible, onCheckedChange = { onTogglePad() }) {
            Icon(Icons.Filled.Piano, contentDescription = stringResource(R.string.reader_editing_pad))
        }
        // Revert lives behind the overflow rather than beside Done, where iOS puts it (`EditorTopBarView` gives it
        // the trailing slot, in red). Two reasons to move it: Material reserves the bar's trailing weight for the
        // PRIMARY action, and this is one a reader takes once in the life of a score — and the bar is already
        // carrying six controls on a 360 dp phone. It stays equally REACHABLE, which is the half that matters for
        // an iOS and an Android reader teaching each other; only its prominence differs.
        //
        // The item is absent, not disabled, when there is nothing to revert to — matching iOS, which shows the
        // control only while `canRevertToOriginal`. On Android that is currently always false; see
        // `EditorBridge.revertToOriginal` for the parity marker covering the missing half.
        if (canRevertToOriginal) {
            EditingOverflowMenu(onRevertToOriginal = onRevertToOriginal)
        }
        TextButton(onClick = onEndEditing) {
            Text(stringResource(R.string.reader_editing_done), fontWeight = FontWeight.SemiBold)
        }
    }
}

/** The overflow the destructive, rarely-reached session actions live in. */
@Composable
private fun EditingOverflowMenu(onRevertToOriginal: () -> Unit) {
    var isOpen by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { isOpen = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.reader_editing_more))
        }
        DropdownMenu(expanded = isOpen, onDismissRequest = { isOpen = false }) {
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(R.string.reader_editing_revert),
                        color = MaterialTheme.colorScheme.error,
                    )
                },
                onClick = {
                    isOpen = false
                    onRevertToOriginal()
                },
            )
        }
    }
}

/**
 * Asks before throwing this session's edits away.
 *
 * Android's answer to iOS's always-visible `✕`: the same CONCEPT — "put back what I just did" — reached by the
 * gesture an Android reader already uses to leave (back, or the bar's arrow), and only when there is something to
 * lose. That keeps the two platforms teachable to each other without ever letting one gesture mean two things:
 * back never silently discards here, and iOS has no back in edit mode at all.
 */
@Composable
fun DiscardEditsDialog(onDiscard: () -> Unit, onKeepEditing: () -> Unit) {
    AlertDialog(
        onDismissRequest = onKeepEditing,
        title = { Text(stringResource(R.string.reader_editing_discard_title)) },
        text = { Text(stringResource(R.string.reader_editing_discard_body)) },
        confirmButton = {
            TextButton(onClick = onDiscard) {
                Text(
                    stringResource(R.string.reader_editing_discard_confirm),
                    color = MaterialTheme.colorScheme.error,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onKeepEditing) {
                Text(stringResource(R.string.reader_editing_discard_keep))
            }
        },
    )
}

/**
 * The voice picker: the active voice's number beside a "voices" glyph, opening a menu of the four.
 *
 * A `TextButton` rather than an `IconButton` because the number has to be readable at a glance — which voice you
 * are writing into changes what every pitch key does, and a picker that only says so once opened would be a trap.
 * The check mark on the open menu's active row is Material's own way of showing a single choice, and is what iOS's
 * `.pickerStyle(.inline)` draws in its menu too.
 */
@Composable
private fun VoicePicker(activeVoice: Int, onSetVoice: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { expanded = true }) {
            Icon(
                Icons.Filled.Groups,
                contentDescription = stringResource(R.string.reader_editing_voice_label),
                modifier = Modifier.size(VOICE_ICON_SIZE),
            )
            Box(Modifier.width(VOICE_ICON_GAP))
            Text("${activeVoice + 1}", fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (voice in 0 until VOICE_COUNT) {
                DropdownMenuItem(
                    // The full "Voice 1" wording, not a bare digit — a menu row has the width for it, and a
                    // column of lone numerals says nothing about what is being chosen (iOS's
                    // `EditorVoicePicker.voiceLabel` makes the same call).
                    text = { Text(stringResource(R.string.reader_editing_voice, voice + 1)) },
                    leadingIcon = {
                        if (voice == activeVoice) {
                            Icon(Icons.Filled.Check, contentDescription = null)
                        }
                    },
                    onClick = {
                        onSetVoice(voice)
                        expanded = false
                    },
                )
            }
        }
    }
}

private val VOICE_ICON_SIZE = 20.dp
private val VOICE_ICON_GAP = 4.dp

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
    EditingTopBarActions(
        canUndo = true,
        canRedo = false,
        activeVoice = 0,
        isPadVisible = false,
        onUndo = {},
        onRedo = {},
        onSetVoice = {},
        onTogglePad = {},
        onEndEditing = {},
        canRevertToOriginal = true,
        onRevertToOriginal = {},
    )
}

@Preview(name = "Editing top-bar actions — pad open, voice 3", showBackground = true)
@Composable
private fun EditingTopBarActionsPadOpenPreview() {
    EditingTopBarActions(
        canUndo = true,
        canRedo = true,
        activeVoice = 2,
        isPadVisible = true,
        onUndo = {},
        onRedo = {},
        onSetVoice = {},
        onTogglePad = {},
        onEndEditing = {},
        canRevertToOriginal = false,
        onRevertToOriginal = {},
    )
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

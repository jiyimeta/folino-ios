package com.keynumber.folino.reader.ink

import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import com.keynumber.folino.reader.AnnotationSessionEndMode
import com.keynumber.folino.reader.R

/**
 * The Reader's app-bar actions while an annotation session is open — the display inspector and the one control that
 * ends the session — REPLACING the reading actions, the same full swap an edit session already does (see
 * [EditingTopBarActions][com.keynumber.folino.reader.editing.EditingTopBarActions]). The leading ✕ lives in the
 * caller ([ReaderTopBar][com.keynumber.folino.reader.ReaderTopBar]), which also owns the `BackHandler` for the
 * system back gesture.
 *
 * Annotating is a session, and a session's header shows the session's controls. Share, score info, "Edit notes" and
 * the playback inspector all say something about a score you are reading rather than one you are writing on, and
 * they stay out of the way for the duration. **The display inspector stays**: staff size, spacing and which staves
 * show all change what is under the pen, so it is the one reading control that is still about the thing being
 * annotated. iOS's annotation strip keeps exactly the same one, for the same reason.
 *
 * **Undo and redo are deliberately absent here, and that is where the two platforms differ on purpose.** iOS puts
 * them in its strip whenever the size class is compact, because PencilKit's own palette drops them in that layout.
 * Android's palette is [AnnotationToolbar], which is always on screen while annotating and always carries its own
 * undo / redo beside the pens — putting a second pair in the app bar would be two controls for one action, at
 * opposite ends of the screen. The rule the platforms share is "undo lives with the pens"; only where the pens live
 * differs.
 */
@Composable
fun AnnotationTopBarActions(
    endMode: AnnotationSessionEndMode,
    onDisplaySettings: () -> Unit,
    /** Ends the session keeping this session's ink — the ✓ half of the trailing control. */
    onEndAnnotating: () -> Unit,
    /** Asks before deleting every annotation on the score — the [AnnotationSessionEndMode.CLEAR_ALL] half. */
    onRequestClearAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        // The same glyph the reading row uses for this sheet, so the button a reader already knows does not change
        // shape when the session opens — only its neighbours go away.
        IconButton(onClick = onDisplaySettings) {
            Icon(
                Icons.AutoMirrored.Filled.Article,
                contentDescription = stringResource(R.string.reader_display_settings),
            )
        }
        AnnotationSessionEndButton(
            endMode = endMode,
            onEndAnnotating = onEndAnnotating,
            onRequestClearAll = onRequestClearAll,
        )
    }
}

/**
 * The trailing control: three controls wearing one slot, which one showing is the whole status readout for the
 * session. Which one that is comes from shared Swift — see
 * [AnnotationSessionEndMode][com.keynumber.folino.reader.AnnotationSessionEndMode] — never from a decision made
 * here.
 *
 * * [AnnotationSessionEndMode.COMMIT_UNCHANGED] — nothing has ever been drawn. Leaving changes nothing, so the
 *   control is flat and quiet.
 * * [AnnotationSessionEndMode.COMMIT_EDITED] — this session drew or erased something. It is already saved, so
 *   leaving still just leaves; the fill is what says the score is no longer what it was when it was opened. Exactly
 *   the statement `EditingTopBarActions`' Done makes with the same emphasis, and iOS makes by turning its checkmark
 *   yellow.
 * * [AnnotationSessionEndMode.CLEAR_ALL] — this session changed nothing, but the score carries ink from before. The
 *   only thing worth offering is undoing THAT, so the control becomes "Revert" on the error colour — destructive,
 *   confirmed, and the one coloured thing in the bar.
 *
 * **One button whose colours and label change, never two different buttons** — the lesson `EditingTopBarActions`
 * records: `TextButton` and `FilledTonalButton` carry different content padding, so swapping between them resizes
 * the control, and this row is laid out from the trailing edge. The label's own width still moves when the mode
 * flips to Revert, but that is a mode change the user caused by putting the pen down, not a control shifting under
 * a finger already aimed at it.
 *
 * Revert asks first ([onRequestClearAll] raises the dialog rather than doing the deed); the other two states leave
 * immediately, because leaving is not a thing to confirm.
 */
@Composable
private fun AnnotationSessionEndButton(
    endMode: AnnotationSessionEndMode,
    onEndAnnotating: () -> Unit,
    onRequestClearAll: () -> Unit,
) {
    val isClearAll = endMode == AnnotationSessionEndMode.CLEAR_ALL
    FilledTonalButton(
        onClick = { if (isClearAll) onRequestClearAll() else onEndAnnotating() },
        colors = when (endMode) {
            AnnotationSessionEndMode.COMMIT_UNCHANGED -> ButtonDefaults.filledTonalButtonColors(
                containerColor = Color.Transparent,
                contentColor = MaterialTheme.colorScheme.primary,
            )
            AnnotationSessionEndMode.COMMIT_EDITED -> ButtonDefaults.filledTonalButtonColors()
            AnnotationSessionEndMode.CLEAR_ALL -> ButtonDefaults.filledTonalButtonColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
            )
        },
    ) {
        Text(
            stringResource(
                if (isClearAll) R.string.reader_annotation_revert else R.string.reader_annotation_done,
            ),
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/**
 * Asks before ✕ throws this session's ink away. Reached the same two ways the edit session's own dialog is — the
 * bar's leading ✕ and the system back gesture — and shown only when there is something to lose, so a session that
 * drew nothing simply leaves. Back never silently discards.
 */
@Composable
fun DiscardAnnotationsDialog(onDiscard: () -> Unit, onKeepAnnotating: () -> Unit) {
    AlertDialog(
        onDismissRequest = onKeepAnnotating,
        title = { Text(stringResource(R.string.reader_annotation_discard_title)) },
        text = { Text(stringResource(R.string.reader_annotation_discard_body)) },
        confirmButton = {
            TextButton(onClick = onDiscard) {
                Text(
                    stringResource(R.string.reader_annotation_discard_confirm),
                    color = MaterialTheme.colorScheme.error,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onKeepAnnotating) {
                Text(stringResource(R.string.reader_annotation_discard_keep))
            }
        },
    )
}

/**
 * Asks before "Revert" deletes every annotation on the score. Unlike the discard dialog this one is never optional:
 * it is offered precisely when the session itself changed nothing, so what it destroys is work from some earlier
 * sitting that the user cannot see being taken away.
 */
@Composable
fun ClearAllAnnotationsDialog(onClearAll: () -> Unit, onCancel: () -> Unit) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.reader_annotation_clear_title)) },
        text = { Text(stringResource(R.string.reader_annotation_clear_body)) },
        confirmButton = {
            TextButton(onClick = onClearAll) {
                Text(
                    stringResource(R.string.reader_annotation_clear_confirm),
                    color = MaterialTheme.colorScheme.error,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Text(stringResource(R.string.reader_annotation_clear_keep))
            }
        },
    )
}

@Preview(name = "Annotation top-bar actions — nothing drawn yet", showBackground = true)
@Composable
private fun AnnotationTopBarActionsUnchangedPreview() {
    AnnotationTopBarActions(
        endMode = AnnotationSessionEndMode.COMMIT_UNCHANGED,
        onDisplaySettings = {},
        onEndAnnotating = {},
        onRequestClearAll = {},
    )
}

/** The state the trailing control has to read as "there is now something worth keeping". */
@Preview(name = "Annotation top-bar actions — this session drew something", showBackground = true)
@Composable
private fun AnnotationTopBarActionsEditedPreview() {
    AnnotationTopBarActions(
        endMode = AnnotationSessionEndMode.COMMIT_EDITED,
        onDisplaySettings = {},
        onEndAnnotating = {},
        onRequestClearAll = {},
    )
}

/** The one coloured state: an untouched session on a score that already carries ink. */
@Preview(name = "Annotation top-bar actions — revert offered", showBackground = true)
@Composable
private fun AnnotationTopBarActionsRevertPreview() {
    AnnotationTopBarActions(
        endMode = AnnotationSessionEndMode.CLEAR_ALL,
        onDisplaySettings = {},
        onEndAnnotating = {},
        onRequestClearAll = {},
    )
}

@Preview(name = "Discard annotations dialog", showBackground = true)
@Composable
private fun DiscardAnnotationsDialogPreview() {
    DiscardAnnotationsDialog(onDiscard = {}, onKeepAnnotating = {})
}

@Preview(name = "Delete all annotations dialog", showBackground = true)
@Composable
private fun ClearAllAnnotationsDialogPreview() {
    ClearAllAnnotationsDialog(onClearAll = {}, onCancel = {})
}

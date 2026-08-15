package com.keynumber.folino.editor

import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import kotlinx.coroutines.flow.StateFlow

/**
 * Everything Compose reads, and nothing it can write.
 *
 * The generated view model publishes both the projection and the ops on one object, so handing it to the UI hands
 * over the ops too — and an op applied outside [EditSessionRelay] leaves its intent frames in the queue for the
 * next relayed op to pick up, which a resync in between turns into a double-apply. There is no way to make that
 * safe from the outside, so the view model does not leave this file: [GeneratedEditBridging] implements this
 * interface over it and keeps the reference private.
 *
 * These flows are for DISPLAY. The relay reads `revision` / `appliedIntentCount` through synchronous ops instead,
 * for the reason `GeneratedEditBridging` documents at length — do not route control flow through here.
 */
interface EditProjection {
    val isSessionActive: StateFlow<Boolean>
    val revision: StateFlow<Int>
    val selectionRevision: StateFlow<Int>
    val canUndo: StateFlow<Boolean>
    val canRedo: StateFlow<Boolean>
    val hasEditTarget: StateFlow<Boolean>
    val isNoteSelected: StateFlow<Boolean>
    val hasSelectionCallout: StateFlow<Boolean>
    val canWriteRest: StateFlow<Boolean>
    val canTie: StateFlow<Boolean>
    val isSelectionTied: StateFlow<Boolean>
    val canAppendTiedNote: StateFlow<Boolean>
    val isCaretInTuplet: StateFlow<Boolean>
    val armedDurationKind: StateFlow<Int>
    val armedDots: StateFlow<Int>
    val isAddToChordArmed: StateFlow<Boolean>
    val armedTuplet: StateFlow<Int>
    val calloutDurationKind: StateFlow<Int>
    val calloutDots: StateFlow<Int>
    val activeVoice: StateFlow<Int>
    val selectedItemFrame: StateFlow<EditBytesWire?>
    val caretItemFrame: StateFlow<EditBytesWire?>
}

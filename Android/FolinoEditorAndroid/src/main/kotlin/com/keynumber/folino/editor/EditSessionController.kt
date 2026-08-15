package com.keynumber.folino.editor

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Why editing is or is not available, in the terms the UI has to explain to a user. */
enum class EditAvailability {
    /** A session is open and every op is live. */
    AVAILABLE,

    /** Folino's engine and the one behind the score handle are different builds (§8.1). Editing cannot be safe. */
    UNAVAILABLE_VERSION_SKEW,

    /** The two copies of the score disagreed and could not be reconciled — `open()` closed the session itself. */
    UNAVAILABLE_DIVERGED,

    /** No score handle, or the file would not parse. */
    UNAVAILABLE_NO_SCORE,
}

data class EditUiState(
    val isEditing: Boolean = false,
    val availability: EditAvailability = EditAvailability.AVAILABLE,
    val canUndo: Boolean = false,
    val canRedo: Boolean = false,
    val hasEditTarget: Boolean = false,
    val isNoteSelected: Boolean = false,
    val hasSelectionCallout: Boolean = false,
    val canWriteRest: Boolean = false,
    val armedDurationKind: Int = 0,
    val armedDots: Int = 0,
    val activeVoice: Int = 0,
    val isPadVisible: Boolean = false,
    val selectedItem: ByteArray? = null,
    val caretItem: ByteArray? = null,
    /** Bumped by the relay's own revision; the render surface keys its re-encode off this. */
    val revision: Int = 0,
) {
    // A data class over ByteArray compares those fields by identity, not content — the default generated equals()
    // would call two ticks unequal even when selectedItem/caretItem hold the same bytes, and this state is what
    // drives recomposition: MutableStateFlow conflates only equal values, so every such tick would reach every
    // collector (the caret overlay and the callout, Tasks 5/8) for no real change. Override with contentEquals() /
    // contentHashCode() for the two array fields and the data class's own field-by-field comparison for the rest.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is EditUiState) return false
        return isEditing == other.isEditing &&
            availability == other.availability &&
            canUndo == other.canUndo &&
            canRedo == other.canRedo &&
            hasEditTarget == other.hasEditTarget &&
            isNoteSelected == other.isNoteSelected &&
            hasSelectionCallout == other.hasSelectionCallout &&
            canWriteRest == other.canWriteRest &&
            armedDurationKind == other.armedDurationKind &&
            armedDots == other.armedDots &&
            activeVoice == other.activeVoice &&
            isPadVisible == other.isPadVisible &&
            selectedItem.contentEquals(other.selectedItem) &&
            caretItem.contentEquals(other.caretItem) &&
            revision == other.revision
    }

    override fun hashCode(): Int {
        var result = isEditing.hashCode()
        result = 31 * result + availability.hashCode()
        result = 31 * result + canUndo.hashCode()
        result = 31 * result + canRedo.hashCode()
        result = 31 * result + hasEditTarget.hashCode()
        result = 31 * result + isNoteSelected.hashCode()
        result = 31 * result + hasSelectionCallout.hashCode()
        result = 31 * result + canWriteRest.hashCode()
        result = 31 * result + armedDurationKind.hashCode()
        result = 31 * result + armedDots.hashCode()
        result = 31 * result + activeVoice.hashCode()
        result = 31 * result + isPadVisible.hashCode()
        result = 31 * result + selectedItem.contentHashCode()
        result = 31 * result + caretItem.contentHashCode()
        result = 31 * result + revision.hashCode()
        return result
    }
}

/** Maps `open()`'s five-case answer down to what the UI has to show. Pure, so it needs no coroutine to test. */
private fun OpenResult.toAvailability(): EditAvailability = when (this) {
    OpenResult.OPENED -> EditAvailability.AVAILABLE
    OpenResult.VERSION_SKEW -> EditAvailability.UNAVAILABLE_VERSION_SKEW
    // A resync that could not converge already closed the session itself (see `OpenResult`'s own doc comment) — the
    // routine second session over any score reaches this, not an exotic one, and it must read as read-only, not as
    // a live session whose every op would silently no-op against a closed relay.
    OpenResult.RESYNC_FAILED -> EditAvailability.UNAVAILABLE_DIVERGED
    OpenResult.NO_HANDLE, OpenResult.SCORE_UNREADABLE, OpenResult.MIRROR_REFUSED ->
        EditAvailability.UNAVAILABLE_NO_SCORE
}

/** The [EditProjection] fields the presentation combine below folds into [EditUiState], grouped to stay within
 * `combine`'s typed overloads (2..5 flows) rather than an indexed, unsafely-cast vararg array. */
private data class SelectionAndCommands(
    val canUndo: Boolean,
    val canRedo: Boolean,
    val hasEditTarget: Boolean,
    val isNoteSelected: Boolean,
)

private data class CalloutAndArming(
    val hasSelectionCallout: Boolean,
    val canWriteRest: Boolean,
    val armedDurationKind: Int,
    val armedDots: Int,
)

private data class VoiceAndFrames(
    val activeVoice: Int,
    val selectedItem: ByteArray?,
    val caretItem: ByteArray?,
    val revision: Int,
)

/**
 * The single state holder between Compose and [EditSessionRelay].
 *
 * "Is a session open, and what does the score look like right now" is answered in exactly one place, and
 * `OpenResult` — which has five failure cases — becomes the single [EditAvailability] the UI renders instead of a
 * `when` the UI would otherwise have to repeat. It is written against [EditSessionOps], not the concrete relay —
 * see that interface's doc comment — so a JVM unit test can drive it with a fake and no device.
 *
 * **No Android types.** This class takes its [CoroutineScope] rather than creating one (the composition root passes
 * a `viewModelScope`), and touches nothing that needs an `Application` or `Context`. `:FolinoEditorAndroid`'s test
 * source set has JUnit 4 and `kotlinx-coroutines` but no Robolectric, so a controller that needed either could not
 * be constructed off-device at all.
 *
 * **`begin()`/`end()` update [ui] synchronously**, without waiting on [scope] to dispatch anything: they write
 * `isEditing` and `availability` straight into the state flow's current value. Everything else — `canUndo` and the
 * rest of [EditProjection]'s live fields — is folded in by a background collector started in [init], which does need
 * [scope] to run. That split is deliberate, not an oversight: it is what lets a JVM test assert on the outcome of
 * `begin()` immediately, with a plain [CoroutineScope] and no `kotlinx-coroutines-test` dispatcher, while Compose
 * still gets a fully reactive `ui` in production.
 *
 * **Every op method is one line** — `fun inputPitch(letter: String) = relay.inputPitch(letter)` — and there are no
 * others: a branch here is a rule Android would have and iOS would not, since the shared Swift core owns editing
 * behavior and this class owns only session lifecycle and presentation state.
 */
class EditSessionController(
    private val relay: EditSessionOps,
    projection: EditProjection,
    scope: CoroutineScope,
) {
    private val _ui = MutableStateFlow(EditUiState())
    val ui: StateFlow<EditUiState> = _ui.asStateFlow()

    init {
        val selectionAndCommands = combine(
            projection.canUndo,
            projection.canRedo,
            projection.hasEditTarget,
            projection.isNoteSelected,
        ) { canUndo, canRedo, hasEditTarget, isNoteSelected ->
            SelectionAndCommands(canUndo, canRedo, hasEditTarget, isNoteSelected)
        }
        val calloutAndArming = combine(
            projection.hasSelectionCallout,
            projection.canWriteRest,
            projection.armedDurationKind,
            projection.armedDots,
        ) { hasSelectionCallout, canWriteRest, armedDurationKind, armedDots ->
            CalloutAndArming(hasSelectionCallout, canWriteRest, armedDurationKind, armedDots)
        }
        val voiceAndFrames = combine(
            projection.activeVoice,
            projection.selectedItemFrame,
            projection.caretItemFrame,
            projection.revision,
        ) { activeVoice, selectedItemFrame, caretItemFrame, revision ->
            VoiceAndFrames(activeVoice, selectedItemFrame?.bytes, caretItemFrame?.bytes, revision)
        }
        scope.launch {
            combine(selectionAndCommands, calloutAndArming, voiceAndFrames) { selection, callout, voice ->
                Triple(selection, callout, voice)
            }.collect { (selection, callout, voice) ->
                _ui.update {
                    it.copy(
                        canUndo = selection.canUndo,
                        canRedo = selection.canRedo,
                        hasEditTarget = selection.hasEditTarget,
                        isNoteSelected = selection.isNoteSelected,
                        hasSelectionCallout = callout.hasSelectionCallout,
                        canWriteRest = callout.canWriteRest,
                        armedDurationKind = callout.armedDurationKind,
                        armedDots = callout.armedDots,
                        activeVoice = voice.activeVoice,
                        selectedItem = voice.selectedItem,
                        caretItem = voice.caretItem,
                        revision = voice.revision,
                    )
                }
            }
        }
    }

    // MARK: - Lifecycle

    fun begin(scorePath: String, scoresDirectory: String, scoreId: String) {
        val result = relay.open(scorePath, scoresDirectory, scoreId)
        _ui.update { it.copy(isEditing = result == OpenResult.OPENED, availability = result.toAvailability()) }
    }

    fun end() {
        relay.close()
        _ui.value = EditUiState()
    }

    // MARK: - The pad disclosure
    //
    // Controller-local UI state, not engine state — see the class doc — so it is the one field here that does not
    // delegate to the relay.

    fun setPadVisible(visible: Boolean) {
        _ui.update { it.copy(isPadVisible = visible) }
    }

    // MARK: - The editing ops
    //
    // One method per pad / callout / bar action, each a one-line delegation to the relay. Nothing here may branch —
    // see the class doc.

    fun selectItem(bytes: ByteArray) = relay.selectItem(bytes)
    fun inputPitch(letter: String) = relay.inputPitch(letter)
    fun deleteSelection() = relay.deleteSelection()
    fun writeRest() = relay.writeRest()
    fun armDuration(kind: Int) = relay.armDuration(kind)
    fun toggleArmedDot() = relay.toggleArmedDot()
    fun setArmedDots(dots: Int) = relay.setArmedDots(dots)
    fun setSelectionDuration(kind: Int) = relay.setSelectionDuration(kind)
    fun setSelectionDots(dots: Int) = relay.setSelectionDots(dots)
    fun toggleSelectionDot() = relay.toggleSelectionDot()
    fun shiftPitch(semitones: Int) = relay.shiftPitch(semitones)
    fun shiftOctave(octaves: Int) = relay.shiftOctave(octaves)
    fun setAccidental(raw: String) = relay.setAccidental(raw)
    fun toggleAddToChord() = relay.toggleAddToChord()
    fun removeSelectedNoteFromChord() = relay.removeSelectedNoteFromChord()
    fun toggleTie() = relay.toggleTie()
    fun appendTiedNote() = relay.appendTiedNote()
    fun createTuplet(actualNotes: Int) = relay.createTuplet(actualNotes)
    fun removeTuplet() = relay.removeTuplet()
    fun selectPreviousElement() = relay.selectPreviousElement()
    fun selectNextElement() = relay.selectNextElement()
    fun setActiveVoice(voice: Int) = relay.setActiveVoice(voice)
    fun setPlaybackActive(active: Boolean) = relay.setPlaybackActive(active)
    fun undo() = relay.undo()
    fun redo() = relay.redo()
}

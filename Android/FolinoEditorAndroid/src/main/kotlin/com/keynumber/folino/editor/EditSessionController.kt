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

/** The tuplet the pad's key writes until its long-press menu picks another — the triplet, and the same default
 * `EditorSessionCore.armedTuplet` carries on the Swift side. Public so the pad's own preview and the key that
 * renders [EditUiState.armedTuplet] can name it rather than hard-coding a 3. */
const val DEFAULT_TUPLET_SIZE = 3

/** What leaving the session offers to do. Mirrors Swift's `EditorSessionEndMode`, which is the authority. */
enum class EditSessionEndMode {
    /** Nothing changed this session and there is no original to go back to — just leave. */
    COMMIT_UNCHANGED,

    /** Nothing changed this session, but an earlier one left an original to revert to. */
    REVERT,

    /** This session changed the score; leaving keeps those edits. */
    COMMIT_EDITED,
    ;

    companion object {
        /** Maps `EditorBridge.sessionEndModeKind`. An unknown value reads as the harmless case rather than
         *  throwing: a bridge one build ahead must not crash the UI over a mode it can simply not offer. */
        fun fromKind(kind: Int): EditSessionEndMode = when (kind) {
            1 -> REVERT
            2 -> COMMIT_EDITED
            else -> COMMIT_UNCHANGED
        }
    }
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
    /** The SELECTED item's own length — what the callout's summary key wears (Task 8), as opposed to
     * [armedDurationKind]/[armedDots], which describe what the NEXT note will be. */
    val calloutDurationKind: Int = 0,
    val calloutDots: Int = 0,
    /** Whether the selection COULD be tied to its same-pitch neighbour, and whether it currently IS — the two
     * halves of what the pad's tie key means (`EditingPad.TieKey`): "tie these" when a neighbour exists, and
     * "these are tied, tap to undo" when the capsule is lit. */
    val canTie: Boolean = false,
    val isSelectionTied: Boolean = false,
    /** Whether there is a rest in the next slot to write the armed length into, so the tie key can APPEND a
     * tied note rather than tie two notes that already exist — iOS's `EditorContextOps.TieButton` gates its
     * own key on exactly this. */
    val canAppendTiedNote: Boolean = false,
    /** Whether the CARET (not the selection) sits inside a tuplet: the tuplet key rides with the durations and,
     * like them, acts on the slot the next note goes into, so this is what decides whether a tap writes a
     * tuplet or takes the caret's slot back out of one. */
    val isCaretInTuplet: Boolean = false,
    /**
     * The tuplet size a plain tap on the tuplet key writes — 3 until the key's long-press menu picks another,
     * after which the key wears that size (a piece that wants quintuplets wants them more than once).
     *
     * Defaults to 3 rather than 0 to match `EditorSessionCore.armedTuplet`'s own default: this value is only
     * ever a copy of the Swift side's, and a 0 here in the window before the first projection tick would put a
     * "0" on the key and ask the core for a 1:1 tuplet (which it refuses outright).
     */
    val armedTuplet: Int = DEFAULT_TUPLET_SIZE,
    /** Whether the next pitch key ADDS to the selected chord instead of replacing the selection — an arming
     * toggle like the durations, not an action, which is why the key lights the same way they do. */
    val isAddToChordArmed: Boolean = false,
    val activeVoice: Int = 0,
    val isPadVisible: Boolean = false,
    val selectedItem: ByteArray? = null,
    val caretItem: ByteArray? = null,
    /** Whether this session has moved the score away from where it opened — what the discard prompt is gated on. */
    val sessionHasEdits: Boolean = false,
    /** Whether an original is recorded to go back to. Always false on Android today. */
    val canRevertToOriginal: Boolean = false,
    val sessionEndMode: EditSessionEndMode = EditSessionEndMode.COMMIT_UNCHANGED,
    /** Whether this session's edits were written to a NEW file — a sibling `.mscz` next to a source format that
     *  cannot carry a note edit. Latched, so the notice can be shown once and then ignored. */
    val didSaveAsSiblingMSCZ: Boolean = false,
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
            calloutDurationKind == other.calloutDurationKind &&
            calloutDots == other.calloutDots &&
            canTie == other.canTie &&
            isSelectionTied == other.isSelectionTied &&
            canAppendTiedNote == other.canAppendTiedNote &&
            isCaretInTuplet == other.isCaretInTuplet &&
            armedTuplet == other.armedTuplet &&
            isAddToChordArmed == other.isAddToChordArmed &&
            activeVoice == other.activeVoice &&
            isPadVisible == other.isPadVisible &&
            sessionHasEdits == other.sessionHasEdits &&
            canRevertToOriginal == other.canRevertToOriginal &&
            sessionEndMode == other.sessionEndMode &&
            selectedItem.contentEquals(other.selectedItem) &&
            caretItem.contentEquals(other.caretItem)
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
        result = 31 * result + calloutDurationKind.hashCode()
        result = 31 * result + calloutDots.hashCode()
        result = 31 * result + canTie.hashCode()
        result = 31 * result + isSelectionTied.hashCode()
        result = 31 * result + canAppendTiedNote.hashCode()
        result = 31 * result + isCaretInTuplet.hashCode()
        result = 31 * result + armedTuplet.hashCode()
        result = 31 * result + isAddToChordArmed.hashCode()
        result = 31 * result + activeVoice.hashCode()
        result = 31 * result + isPadVisible.hashCode()
        result = 31 * result + sessionHasEdits.hashCode()
        result = 31 * result + canRevertToOriginal.hashCode()
        result = 31 * result + sessionEndMode.hashCode()
        result = 31 * result + selectedItem.contentHashCode()
        result = 31 * result + caretItem.contentHashCode()
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
)

/** The callout's own display fields (Task 8) — the SELECTED item's length and tie-ability, as opposed to
 * [CalloutAndArming], which is about the NEXT note. Kept separate from that group rather than folded into it:
 * `combine`'s typed overloads top out at 5 flows, and [CalloutAndArming] is already at 4. */
private data class CalloutDisplay(
    val calloutDurationKind: Int,
    val calloutDots: Int,
    val canTie: Boolean,
    val isSelectionTied: Boolean,
)

/** What the pad's chord / tie / tuplet keys read — the group named after the Swift extension that owns all three
 * ops (`EditorSessionCore+ChordTieTuplet.swift`), since they arrive together and are read together.
 *
 * A fifth group rather than additions to [CalloutAndArming] or [CalloutDisplay] for the reason those two are
 * already split from each other: `combine`'s typed overloads take at most 5 flows, and both are at 4. Five groups
 * is also the ceiling for the OUTER fold below — a sixth field group would have to be nested one level deeper
 * (group the groups), never flattened into an indexed vararg `combine`, whose lambda hands back an
 * `Array<Any?>` every element of which needs an unchecked cast.
 */
private data class ChordTieTupletArming(
    val canAppendTiedNote: Boolean,
    val isCaretInTuplet: Boolean,
    val armedTuplet: Int,
    val isAddToChordArmed: Boolean,
)

/** The five grouped flows [EditSessionController.init] folds into one [EditUiState] tick — named fields rather
 * than a tuple type this file would otherwise have to invent. */
/** The end-of-session answers, grouped as the sixth block — see the nested fold in [EditSessionController.init]. */
private data class SessionEnd(
    val sessionHasEdits: Boolean,
    val canRevertToOriginal: Boolean,
    val sessionEndMode: EditSessionEndMode,
    val didSaveAsSiblingMSCZ: Boolean,
)

private data class CombinedProjection(
    val selection: SelectionAndCommands,
    val callout: CalloutAndArming,
    val voice: VoiceAndFrames,
    val calloutDisplay: CalloutDisplay,
    val chordTieTuplet: ChordTieTupletArming,
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
        // `projection.revision` is deliberately NOT folded in. It used to ride along as a fourth field of
        // [EditUiState], documented as what the render surface keyed its re-encode off — which was never true: the
        // selection tint keys on `ReaderViewModel.layoutGeneration`, since a re-encode has to follow the RELAYOUT an
        // edit causes, not the edit itself. Nothing read it, so it is gone rather than left as a field whose comment
        // described a wiring that did not exist. The relay still reads the revision where it genuinely matters, via
        // the synchronous `EditSessionOps.revision()` (see `EditSessionRelay.replay`).
        val voiceAndFrames = combine(
            projection.activeVoice,
            projection.selectedItemFrame,
            projection.caretItemFrame,
        ) { activeVoice, selectedItemFrame, caretItemFrame ->
            VoiceAndFrames(activeVoice, selectedItemFrame?.bytes, caretItemFrame?.bytes)
        }
        val calloutDisplay = combine(
            projection.calloutDurationKind,
            projection.calloutDots,
            projection.canTie,
            projection.isSelectionTied,
        ) { calloutDurationKind, calloutDots, canTie, isSelectionTied ->
            CalloutDisplay(calloutDurationKind, calloutDots, canTie, isSelectionTied)
        }
        val chordTieTuplet = combine(
            projection.canAppendTiedNote,
            projection.isCaretInTuplet,
            projection.armedTuplet,
            projection.isAddToChordArmed,
        ) { canAppendTiedNote, isCaretInTuplet, armedTuplet, isAddToChordArmed ->
            ChordTieTupletArming(canAppendTiedNote, isCaretInTuplet, armedTuplet, isAddToChordArmed)
        }
        val sessionEnd = combine(
            projection.sessionHasEdits,
            projection.canRevertToOriginal,
            projection.sessionEndModeKind,
            projection.didSaveAsSiblingMSCZ,
        ) { sessionHasEdits, canRevertToOriginal, endModeKind, savedAsSibling ->
            SessionEnd(
                sessionHasEdits,
                canRevertToOriginal,
                EditSessionEndMode.fromKind(endModeKind),
                savedAsSibling,
            )
        }
        // A SIXTH group does not fit `combine`'s typed overloads (they stop at five), so the five fold first and
        // this one joins the result — a two-flow combine, which is the nesting `ChordTieTupletArming`'s own comment
        // anticipated. Nested rather than switched to the indexed vararg overload: that one hands back an
        // `Array<Any?>` every field has to be cast out of, and a wrong cast there compiles and fails at runtime.
        val combined = combine(
            selectionAndCommands, calloutAndArming, voiceAndFrames, calloutDisplay, chordTieTuplet,
        ) { selection, callout, voice, display, arming ->
            CombinedProjection(selection, callout, voice, display, arming)
        }
        scope.launch {
            combine(combined, sessionEnd) { projected, ending ->
                projected to ending
            }.collect { (projected, ending) ->
                val (selection, callout, voice, display, arming) = projected
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
                        calloutDurationKind = display.calloutDurationKind,
                        calloutDots = display.calloutDots,
                        canTie = display.canTie,
                        isSelectionTied = display.isSelectionTied,
                        canAppendTiedNote = arming.canAppendTiedNote,
                        isCaretInTuplet = arming.isCaretInTuplet,
                        armedTuplet = arming.armedTuplet,
                        isAddToChordArmed = arming.isAddToChordArmed,
                        sessionHasEdits = ending.sessionHasEdits,
                        canRevertToOriginal = ending.canRevertToOriginal,
                        sessionEndMode = ending.sessionEndMode,
                        didSaveAsSiblingMSCZ = ending.didSaveAsSiblingMSCZ,
                        activeVoice = voice.activeVoice,
                        selectedItem = voice.selectedItem,
                        caretItem = voice.caretItem,
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

    /**
     * Writes any pending edit now. Called from the Reader's `ON_PAUSE`, which is the last moment Android guarantees
     * before a process can be killed — the same place the annotation save is flushed from. [end] covers leaving the
     * Reader; this covers being backgrounded while still in it.
     */
    fun flushPendingSave() = relay.flushPendingSave()

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

    /** Throws this session's edits away, back to the score it opened on. */
    fun discardSessionEdits() = relay.discardSessionEdits()

    /**
     * Restores the file from the copy taken at import. Answers `false` when it could not — which is always, today:
     * Android has no originals store yet. The parity marker lives on `EditorBridge.revertToOriginal`.
     */
    fun revertToOriginal(): Boolean = relay.revertToOriginal()
}

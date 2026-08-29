package com.keynumber.folino.editor

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [EditSessionController] — the state holder between Compose and [EditSessionRelay], tested against
 * fakes for [EditSessionOps] and [EditProjection] so none of it needs a device or a real relay.
 *
 * `scope` is a plain [CoroutineScope] rather than a `TestScope` for almost every case here, and deliberately stays
 * one: [EditSessionController.begin] and [EditSessionController.end] write `isEditing`/`availability` into `ui`
 * synchronously — see the class doc — so those assertions need no dispatcher to actually run anything, and saying so
 * with a plain scope keeps the distinction visible. (`kotlinx-coroutines-test` is on this module's classpath now, for
 * `DebouncedAutosaveTest`.) The one case that DOES need the scheduler is the collected-field test at the bottom,
 * which says so where it sits.
 */
private val scope = CoroutineScope(Dispatchers.Unconfined + Job())

private class FakeRelay(private val openResult: OpenResult = OpenResult.OPENED) : EditSessionOps {
    var openCalls = 0
    var closeCalls = 0

    /** Records every op call by name, so a test can assert a controller method reached the right one. */
    val calls = mutableListOf<String>()

    /** The bytes the last [open] was handed — what a test asserts the reader's carried selection reached. */
    var openedWithCarriedItem: ByteArray? = null

    override fun open(
        scorePath: String,
        scoresDirectory: String,
        scoreId: String,
        carriedItem: ByteArray,
    ): OpenResult {
        openCalls += 1
        openedWithCarriedItem = carriedItem
        return openResult
    }

    override fun close() { closeCalls += 1 }

    var flushCalls = 0
    override fun flushPendingSave() { flushCalls += 1 }

    override fun selectItem(bytes: ByteArray) { calls += "selectItem" }
    override fun inputPitch(letter: String) { calls += "inputPitch($letter)" }
    override fun deleteSelection() { calls += "deleteSelection" }
    override fun writeRest() { calls += "writeRest" }
    override fun armDuration(kind: Int) { calls += "armDuration($kind)" }
    override fun toggleArmedDot() { calls += "toggleArmedDot" }
    override fun setArmedDots(dots: Int) { calls += "setArmedDots($dots)" }
    override fun setSelectionDuration(kind: Int) { calls += "setSelectionDuration($kind)" }
    override fun setSelectionDots(dots: Int) { calls += "setSelectionDots($dots)" }
    override fun toggleSelectionDot() { calls += "toggleSelectionDot" }
    override fun shiftPitch(semitones: Int) { calls += "shiftPitch($semitones)" }
    override fun shiftOctave(octaves: Int) { calls += "shiftOctave($octaves)" }
    override fun setAccidental(raw: String) { calls += "setAccidental($raw)" }
    override fun toggleAddToChord() { calls += "toggleAddToChord" }
    override fun removeSelectedNoteFromChord() { calls += "removeSelectedNoteFromChord" }
    override fun toggleTie() { calls += "toggleTie" }
    override fun appendTiedNote() { calls += "appendTiedNote" }
    override fun createTuplet(actualNotes: Int) { calls += "createTuplet($actualNotes)" }
    override fun removeTuplet() { calls += "removeTuplet" }
    override fun selectPreviousElement() { calls += "selectPreviousElement" }
    override fun selectNextElement() { calls += "selectNextElement" }
    override fun setActiveVoice(voice: Int) { calls += "setActiveVoice($voice)" }
    override fun setPlaybackActive(active: Boolean) { calls += "setPlaybackActive($active)" }
    override fun discardSessionEdits() { calls += "discardSessionEdits()" }
    override fun revertToOriginal(): Boolean { calls += "revertToOriginal()"; return false }
    override fun undo() { calls += "undo" }
    override fun redo() { calls += "redo" }
}

private class FakeProjection : EditProjection {
    override val isSessionActive = MutableStateFlow(false)
    override val revision = MutableStateFlow(0)
    override val selectionRevision = MutableStateFlow(0)
    override val canUndo = MutableStateFlow(false)
    override val canRedo = MutableStateFlow(false)
    override val hasEditTarget = MutableStateFlow(false)
    override val isNoteSelected = MutableStateFlow(false)
    override val hasSelectionCallout = MutableStateFlow(false)
    override val canWriteRest = MutableStateFlow(false)
    override val canTie = MutableStateFlow(false)
    override val isSelectionTied = MutableStateFlow(false)
    override val canAppendTiedNote = MutableStateFlow(false)
    override val isCaretInTuplet = MutableStateFlow(false)
    override val armedDurationKind = MutableStateFlow(0)
    override val armedDots = MutableStateFlow(0)
    override val isAddToChordArmed = MutableStateFlow(false)
    override val armedTuplet = MutableStateFlow(0)
    override val calloutDurationKind = MutableStateFlow(0)
    override val calloutDots = MutableStateFlow(0)
    override val activeVoice = MutableStateFlow(0)
    override val sessionHasEdits = MutableStateFlow(false)
    override val canRevertToOriginal = MutableStateFlow(false)
    override val didSaveAsSiblingMSCZ = MutableStateFlow(false)
    override val sessionEndModeKind = MutableStateFlow(0)
    override val selectedItemFrame = MutableStateFlow<EditBytesWire?>(null)
    override val caretItemFrame = MutableStateFlow<EditBytesWire?>(null)
}

class EditSessionControllerTest {
    // MARK: - begin()'s mapping from OpenResult to EditAvailability

    @Test
    fun `a refused open leaves the session read-only with a reason`() {
        val relay = FakeRelay(openResult = OpenResult.VERSION_SKEW)
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.begin("/score.mscx", "/scores", "id")

        assertEquals(EditAvailability.UNAVAILABLE_VERSION_SKEW, controller.ui.value.availability)
        assertFalse(controller.ui.value.isEditing)
    }

    @Test
    fun `a resync that could not converge is read-only too, not a live session`() {
        // `open()` returns RESYNC_FAILED for a session it already had to close — the routine second session over
        // any score reaches it. Reporting it as OPENED hands the UI a live-looking session whose every op no-ops.
        val relay = FakeRelay(openResult = OpenResult.RESYNC_FAILED)
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.begin("/score.mscx", "/scores", "id")

        assertEquals(EditAvailability.UNAVAILABLE_DIVERGED, controller.ui.value.availability)
        assertFalse(controller.ui.value.isEditing)
    }

    @Test
    fun `a successful open is live and available`() {
        val relay = FakeRelay(openResult = OpenResult.OPENED)
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.begin("/score.mscx", "/scores", "id")

        assertEquals(EditAvailability.AVAILABLE, controller.ui.value.availability)
        assertTrue(controller.ui.value.isEditing)
    }

    @Test
    fun `begin hands the reader's last tap through to the session it opens`() {
        val relay = FakeRelay(openResult = OpenResult.OPENED)
        val controller = EditSessionController(relay, FakeProjection(), scope)
        val tapped = byteArrayOf(4, 2)

        controller.begin("/score.mscx", "/scores", "id", tapped)

        assertArrayEquals(tapped, relay.openedWithCarriedItem)
    }

    /** Nothing tapped is the ordinary cold open, and it must still reach the relay as "carry nothing" rather than
     * as a missing argument some layer defaults differently. */
    @Test
    fun `begin with nothing remembered carries empty bytes`() {
        val relay = FakeRelay(openResult = OpenResult.OPENED)
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.begin("/score.mscx", "/scores", "id")

        assertArrayEquals(ByteArray(0), relay.openedWithCarriedItem)
    }

    @Test
    fun `no handle, an unreadable score, and a refused mirror all read the same to the user`() {
        for (result in listOf(OpenResult.NO_HANDLE, OpenResult.SCORE_UNREADABLE, OpenResult.MIRROR_REFUSED)) {
            val controller = EditSessionController(FakeRelay(openResult = result), FakeProjection(), scope)

            controller.begin("/score.mscx", "/scores", "id")

            assertEquals(EditAvailability.UNAVAILABLE_NO_SCORE, controller.ui.value.availability)
            assertFalse(controller.ui.value.isEditing)
        }
    }

    // MARK: - end()

    @Test
    fun `end closes the relay and resets ui to its default`() {
        val relay = FakeRelay(openResult = OpenResult.OPENED)
        val controller = EditSessionController(relay, FakeProjection(), scope)
        controller.begin("/score.mscx", "/scores", "id")

        controller.end()

        assertEquals(1, relay.closeCalls)
        assertEquals(EditUiState(), controller.ui.value)
    }

    // MARK: - EditUiState's ByteArray equality override

    @Test
    fun `EditUiState compares selectedItem and caretItem by content, not identity`() {
        val a = EditUiState(selectedItem = byteArrayOf(1, 2, 3), caretItem = byteArrayOf(4, 5))
        // Distinct array instances, same bytes — a fresh EditBytesWire built from identical content on the next
        // tick must still compare equal, or MutableStateFlow would push a no-op emission to every collector.
        val b = EditUiState(selectedItem = byteArrayOf(1, 2, 3), caretItem = byteArrayOf(4, 5))
        val differentSelected = EditUiState(selectedItem = byteArrayOf(9), caretItem = byteArrayOf(4, 5))
        val differentCaret = EditUiState(selectedItem = byteArrayOf(1, 2, 3), caretItem = byteArrayOf(9))

        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertTrue(a != differentSelected)
        assertTrue(a != differentCaret)
    }

    @Test
    fun `EditUiState's hand-written equals compares the callout display fields Task 8 added`() {
        // Not a data class default: the hand-written equals()/hashCode() enumerate every field explicitly (see
        // that method's own doc comment on why), so a field added to the constructor but forgotten in either
        // method is silently excluded from equality — this pins calloutDurationKind against exactly that trap.
        val a = EditUiState(calloutDurationKind = 3, calloutDots = 1, canTie = true, isSelectionTied = false)
        val b = EditUiState(calloutDurationKind = 3, calloutDots = 1, canTie = true, isSelectionTied = false)
        val differentDurationKind = a.copy(calloutDurationKind = 4)

        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertTrue(a != differentDurationKind)
    }

    @Test
    fun `EditUiState's hand-written equals compares the pad's chord, tie and tuplet fields`() {
        // The same trap the callout-field test above pins, for the four fields the pad's tuplet / tie /
        // add-to-chord keys read: a field added to the constructor but forgotten in equals() (or in hashCode())
        // is silently excluded from equality, and MutableStateFlow would then conflate away the very tick that
        // lights or dims one of those keys.
        val a = EditUiState(
            canAppendTiedNote = true, isCaretInTuplet = true, armedTuplet = 5, isAddToChordArmed = true,
        )
        val b = EditUiState(
            canAppendTiedNote = true, isCaretInTuplet = true, armedTuplet = 5, isAddToChordArmed = true,
        )

        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertTrue(a != a.copy(canAppendTiedNote = false))
        assertTrue(a != a.copy(isCaretInTuplet = false))
        assertTrue(a != a.copy(armedTuplet = 3))
        assertTrue(a != a.copy(isAddToChordArmed = false))
    }

    @Test
    fun `armedTuplet defaults to the triplet the Swift core also defaults to`() {
        // Not 0: the pad's tuplet key WEARS this number and passes it to `createTuplet`, and the core refuses
        // anything below 2 outright — so the pre-first-tick value has to be a size the key can actually write.
        assertEquals(DEFAULT_TUPLET_SIZE, EditUiState().armedTuplet)
        assertEquals(3, DEFAULT_TUPLET_SIZE)
    }

    // MARK: - Op delegation — each op method is a one-line forward to the relay

    @Test
    fun `op methods delegate to the relay unchanged`() {
        val relay = FakeRelay()
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.inputPitch("C")
        controller.deleteSelection()
        controller.armDuration(4)
        controller.setActiveVoice(2)
        controller.undo()
        controller.redo()

        assertEquals(
            listOf("inputPitch(C)", "deleteSelection", "armDuration(4)", "setActiveVoice(2)", "undo", "redo"),
            relay.calls,
        )
    }

    @Test
    fun `the pad's chord, tie, tuplet and stepper ops reach the relay unchanged`() {
        // These existed on the controller before any key called them (the pad's tuplet / tie / add-to-chord keys
        // and its ← / → steppers). Now that the UI drives them, pin that each is still the same one-line forward
        // — above all `createTuplet`, whose argument is the size the key wears and must not be rewritten here.
        val relay = FakeRelay()
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.toggleAddToChord()
        controller.toggleTie()
        controller.appendTiedNote()
        controller.createTuplet(5)
        controller.removeTuplet()
        controller.selectPreviousElement()
        controller.selectNextElement()

        assertEquals(
            listOf(
                "toggleAddToChord", "toggleTie", "appendTiedNote", "createTuplet(5)", "removeTuplet",
                "selectPreviousElement", "selectNextElement",
            ),
            relay.calls,
        )
    }

    // MARK: - Persistence

    /**
     * The Reader shows a Snackbar off this. It is latched on the Swift side, so the controller only has to carry
     * it — a session that saved to a sibling copy keeps saying so for the rest of its life.
     *
     * The one test here that needs a test scheduler: this is a COLLECTED field, folded in by the background
     * collector [EditSessionController.init] starts (see the class doc for why `begin`/`end` are the synchronous
     * exceptions), so there is a dispatch between setting the flow and reading `ui`. The file-level [scope] cannot
     * express "let that dispatch run" — `runCurrent()` can.
     */
    @Test
    fun `the sibling-mscz notice reaches the ui state`() = runTest {
        val projection = FakeProjection()
        val controller = EditSessionController(FakeRelay(), projection, backgroundScope)

        projection.didSaveAsSiblingMSCZ.value = true
        runCurrent()

        assertTrue(controller.ui.value.didSaveAsSiblingMSCZ)
    }

    @Test
    fun `flushPendingSave forwards to the relay without ending the session`() {
        val relay = FakeRelay()
        val controller = EditSessionController(relay, FakeProjection(), scope)

        controller.flushPendingSave()

        assertEquals(1, relay.flushCalls)
        assertEquals("onPause writes; it does not leave", 0, relay.closeCalls)
    }
}

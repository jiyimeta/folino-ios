package com.keynumber.folino.editor

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [EditSessionController] — the state holder between Compose and [EditSessionRelay], tested against
 * fakes for [EditSessionOps] and [EditProjection] so none of it needs a device or a real relay.
 *
 * `scope` is a plain [CoroutineScope], not a `kotlinx-coroutines-test` `TestScope`: this module's test classpath has
 * no `kotlinx-coroutines-test` (see `ReaderViewportMotionArbitrationTest`'s doc comment for the same constraint
 * elsewhere in this repo). That is fine here because [EditSessionController.begin] and
 * [EditSessionController.end] write `isEditing`/`availability` into `ui` synchronously — see the class doc — so
 * every assertion below needs no dispatcher to actually run anything.
 */
private val scope = CoroutineScope(Dispatchers.Unconfined + Job())

private class FakeRelay(private val openResult: OpenResult = OpenResult.OPENED) : EditSessionOps {
    var openCalls = 0
    var closeCalls = 0

    /** Records every op call by name, so a test can assert a controller method reached the right one. */
    val calls = mutableListOf<String>()

    override fun open(scorePath: String, scoresDirectory: String, scoreId: String): OpenResult {
        openCalls += 1
        return openResult
    }

    override fun close() { closeCalls += 1 }

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
        controller.setPadVisible(true)

        controller.end()

        assertEquals(1, relay.closeCalls)
        assertEquals(EditUiState(), controller.ui.value)
    }

    // MARK: - The pad disclosure

    @Test
    fun `setPadVisible is controller-local and defaults to closed`() {
        val controller = EditSessionController(FakeRelay(), FakeProjection(), scope)
        assertFalse(controller.ui.value.isPadVisible)

        controller.setPadVisible(true)
        assertTrue(controller.ui.value.isPadVisible)

        controller.setPadVisible(false)
        assertFalse(controller.ui.value.isPadVisible)
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
}

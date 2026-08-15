package com.keynumber.folino.editor

import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * SP4's acceptance gate for the UI layer that sits on top of [EditSessionRelay]: [EditSessionController] and the
 * [EditUiState] Compose actually renders from. [EditSessionParityTest] already proves the relay keeps the local
 * bridge and the mirror score in lock-step through a scripted sequence of ops; this test proves the SAME thing is
 * true one layer up, through the object graph `MainActivity` actually assembles (`GeneratedEditBridging` ->
 * `EditSessionRelay` -> `EditSessionController`), and asserts on the fields a user-visible UI would react to
 * (`isEditing`, `canUndo`, `isNoteSelected`, `hasSelectionCallout`) rather than on relay call counts.
 *
 * ## Why this checks the mirror's fingerprint too, not just [EditUiState]
 *
 * The Critical this plan exists to catch — `undo()`/`redo()` never reaching the mirror score — is invisible to
 * [EditUiState] alone: `canUndo`/`canRedo` are folded from the SAME [GeneratedEditBridging] instance that always
 * updated correctly, so a controller that only asserted on `ui.value` would report green even if the mirror (the
 * copy behind [TestHost.handle], the one MIDI render / relayout / save would actually use) silently stayed on the
 * pre-undo score. So every step below reads `bridge.scoreFingerprint()` (local) against
 * `SheetMusicJNI.nativeScoreFingerprint(host.handle)` (mirror) in addition to the UI-facing assertions — the
 * fingerprint pair is the ground truth; [EditUiState] is what a user would actually see change.
 *
 * ## Everything that touches the session, the relay or the controller runs on the main thread
 *
 * Exactly the hazard [EditSessionParityTest] documents: the generated view model republishes every projection
 * property with `viewModelScope.launch(Dispatchers.Main)`, which POSTS even when already running on the main
 * thread. A previous device test drove the relay from the instrumentation thread and won that race, reporting green
 * on the exact bug class this test exists to catch. [onMain] (identical in shape to the parity test's) is therefore
 * not ceremony: every call into [EditSessionController], [EditSessionRelay], [GeneratedEditBridging] or the mirror
 * handle goes through it, and [controllerScope] itself is pinned to `Dispatchers.Main.immediate` so the controller's
 * own projection-collecting coroutine (started in its `init`) runs on that same thread rather than a test
 * dispatcher — matching the `rememberCoroutineScope()` `MainActivity` hands it in production. Only
 * `waitForIdleSync()` and the assertions run on the instrumentation thread, and `waitForIdleSync()` is what drains
 * the posted projection updates before those assertions read them.
 */
class EditingUiTest {
    private class TestHost(var handle: Long) : EditSessionHost {
        var relayouts = 0
        override fun scoreHandle() = handle
        override fun replaceScoreHandle(handle: Long) { this.handle = handle }
        override fun requestRelayout() { relayouts += 1 }
    }

    private lateinit var host: TestHost
    private lateinit var relay: EditSessionRelay
    private lateinit var bridge: GeneratedEditBridging
    private lateinit var controller: EditSessionController
    private lateinit var controllerJob: Job

    /** Runs [body] on the app's main thread and rethrows anything it threw on this one — see the class doc. */
    private fun onMain(body: () -> Unit) {
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try {
                body()
            } catch (throwable: Throwable) {
                failure = throwable
            }
        }
        failure?.let { throw it }
    }

    @After
    fun tearDown() {
        onMain {
            controller.end()
            controllerJob.cancel()
            SheetMusicJNI.nativeReleaseScore(host.handle)
        }
    }

    @Test
    fun writingAPitchThenUndoingReturnsTheUiAndTheMirrorToWhereTheyStarted() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scoresDir = File(context.filesDir, "Scores").apply { mkdirs() }
        val file = File(scoresDir, "editing-ui.mscz")
        context.assets.open("parity.mscz").use { input -> file.outputStream().use { input.copyTo(it) } }

        val handle = SheetMusicJNI.nativeLoadScore(file.readBytes())
        assertNotEquals(0L, handle)
        host = TestHost(handle)

        onMain {
            // `Dispatchers.Main.immediate`, not a bare `Dispatchers.Main`: the controller's `init` launches a
            // coroutine off this scope to collect the projection, and it must run on the SAME thread the generated
            // view model posts its updates to — a plain (non-immediate) Main dispatcher would still be correct here
            // in principle, but `.immediate` is what makes the controller's own construction (and its first,
            // synchronous-looking collect of the initial projection values) behave the way it does under
            // `rememberCoroutineScope()` in production, so pin the same thing here rather than a looser stand-in.
            controllerJob = Job()
            val scope = CoroutineScope(Dispatchers.Main.immediate + controllerJob)
            bridge = GeneratedEditBridging(EditorBridgeViewModel.create(EditorRoomFiles()))
            relay = EditSessionRelay(bridge, host, RealEditNatives)
            controller = EditSessionController(relay, bridge, scope)
        }

        onMain { controller.begin(file.path, scoresDir.path, "editing-ui") }
        assertTrue("open() must have entered a live session", controller.ui.value.isEditing)
        assertEquals(EditAvailability.AVAILABLE, controller.ui.value.availability)

        // Stand in for SP4's tap: select the fixture's first rest by ID, exactly as `EditSessionParityTest` does —
        // `EditorSessionCore.selectNextElement()` is a no-op with nothing selected, so a cold session has no target
        // for a real hit-test to land on.
        onMain { controller.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID()))) }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertTrue("the selection must have taken", controller.ui.value.hasEditTarget)

        var baseLocal = 0L
        var baseMirror = 0L
        onMain {
            baseLocal = bridge.scoreFingerprint()
            baseMirror = SheetMusicJNI.nativeScoreFingerprint(host.handle)
        }
        assertEquals("local and mirror must agree before any edit", baseLocal, baseMirror)

        onMain {
            controller.armDuration(QUARTER)
            controller.inputPitch("C")
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertTrue("writing a pitch must turn the rest into a selected note", controller.ui.value.isNoteSelected)
        assertTrue("a selected note must show the callout", controller.ui.value.hasSelectionCallout)
        assertTrue("the session must report an edit happened", controller.ui.value.canUndo)

        var editedLocal = 0L
        var editedMirror = 0L
        onMain {
            editedLocal = bridge.scoreFingerprint()
            editedMirror = SheetMusicJNI.nativeScoreFingerprint(host.handle)
        }
        assertEquals("local and mirror must agree after writing the pitch", editedLocal, editedMirror)
        assertNotEquals("writing a pitch must have changed the score", baseLocal, editedLocal)

        // This is the pass the whole test exists for: undo driven off the main thread, the way production drives
        // it, must reach the mirror. A relay that regressed to the SP3 bug would leave `host.handle`'s fingerprint
        // at `editedMirror` here even though the local copy (and therefore `canUndo`) already looks reverted.
        onMain { controller.undo() }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertFalse("the one edit must have been the only thing to undo", controller.ui.value.canUndo)

        var revertedLocal = 0L
        var revertedMirror = 0L
        onMain {
            revertedLocal = bridge.scoreFingerprint()
            revertedMirror = SheetMusicJNI.nativeScoreFingerprint(host.handle)
        }
        assertEquals("local and mirror must agree after undo", revertedLocal, revertedMirror)
        assertEquals("the score must return to where it started", baseLocal, revertedLocal)
        assertEquals("the MIRROR specifically must return to where it started", baseMirror, revertedMirror)

        // The bug class named in the class doc covers redo as well as undo (both went through the same stale-read
        // path), so close the loop rather than leaving redo unexercised by this gate.
        onMain { controller.redo() }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertTrue("redo must be available and must restore the edit", controller.ui.value.isNoteSelected)

        var redoneLocal = 0L
        var redoneMirror = 0L
        onMain {
            redoneLocal = bridge.scoreFingerprint()
            redoneMirror = SheetMusicJNI.nativeScoreFingerprint(host.handle)
        }
        assertEquals("local and mirror must agree after redo", redoneLocal, redoneMirror)
        assertEquals("redo must land back on the edited score", editedLocal, redoneLocal)
    }

    private companion object {
        const val QUARTER = 3

        /** Same fixture, same first-rest coordinates as `EditSessionParityTest` — see that test's companion doc. */
        fun firstRestID() = RestID(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
            measureIndex = 0,
            voiceIndex = 0,
            elementIndex = 3,
        )
    }
}

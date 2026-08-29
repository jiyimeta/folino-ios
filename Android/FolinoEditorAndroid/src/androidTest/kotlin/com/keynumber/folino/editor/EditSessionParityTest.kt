package com.keynumber.folino.editor

import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.editor.generated.EditorBridgeViewModel
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The SP3 acceptance test: an editing session driven through the real funnel, with the two images' fingerprints
 * compared after EVERY step rather than on the sampling interval.
 *
 * The sampling interval is a shipping compromise about cost; this test is about correctness, so it checks
 * everything. A divergence that the shipped sampling would have caught eight edits later shows up here on the edit
 * that caused it.
 *
 * The test encodes a `ScoreItemID` itself to seed the first selection. That is the one place Kotlin is allowed to
 * speak this schema: `EditorSessionCore.selectNextElement()` is a no-op with nothing selected, so a cold session has
 * no target, and here the test is standing in for SP4's tap. The shipping path still gets its bytes from
 * `nativeEditingHitTest` and relays them without looking.
 *
 * All three `@Test` methods run in the SAME app process (androidx.test does not fork a fresh process per method), so
 * every session opened here is tracked and torn down in [tearDown] — including on the path where an assertion
 * fails and aborts the rest of the test method. Without that, a failed assertion mid-test skips the `relay.close()`
 * / `nativeReleaseScore()` at the bottom of the method, leaking a still-open mirror session into whichever test runs
 * next. Each test also uses its own `scoreId` / staged file name so no two sessions — even across different test
 * methods — ever share either.
 *
 * ## Everything that touches the relay runs on the main thread
 *
 * [onMain] is not ceremony. The relay's contract is "one thread, and on Android that thread is Compose's main
 * thread" (see its doc), and the main thread is not interchangeable with the instrumentation thread here: the
 * generated view model publishes its projection with `viewModelScope.launch(Dispatchers.Main)`, which *posts*.
 * Driving the relay off-thread lets those posts run concurrently with the op, which is a race — and a race this
 * test used to win, hiding a bug (`undo`/`redo` never reaching the mirror) that was deterministic in production.
 * So every relay call, every bridge read and every teardown goes through [onMain], and only the assertions run out
 * here. `waitForIdleSync()` stays where projection state is read back afterwards: those updates are still posted,
 * and it must be called from *this* thread, never from inside [onMain].
 */
class EditSessionParityTest {
    /**
     * Mirrors the production host's OWNERSHIP, not just its state.
     *
     * `EditSessionHost.replaceScoreHandle` gives the host the handle it displaced and the relay never frees it, so
     * a fake that merely overwrote its field would exercise a lifetime no real host has — and this test is the
     * acceptance gate for the relay design, so it is the one place a lifetime regression would be caught.
     * [retired] collects the superseded handles exactly as `ReaderViewModel.retiredScoreHandles` does; [tearDown]
     * releases them. There is no equivalent of the audio engine here to refuse a release, so this fake's drain is
     * unconditional where production's consults a probe — the property under test is that the relay leaves the
     * freeing to the host, which both spellings share.
     */
    private class TestHost(var handle: Long) : EditSessionHost {
        var relayouts = 0
        val retired = mutableListOf<Long>()
        override fun scoreHandle() = handle
        override fun replaceScoreHandle(handle: Long) {
            if (this.handle != 0L && this.handle != handle) retired += this.handle
            this.handle = handle
        }
        override fun requestRelayout() { relayouts += 1 }
    }

    private class Rig(val bridge: GeneratedEditBridging, val host: TestHost, val relay: EditSessionRelay)

    // Torn down in `tearDown()` regardless of whether the test method that populated them passed or threw.
    // `hostsToRelease` is deduplicated by identity in `tearDown()`: `reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging`
    // opens a second session against the SAME `TestHost` as its first (that reuse is the point of the test), and
    // releasing `host.handle` twice for one still-live handle would be a double-release.
    private val relaysToClose = mutableListOf<EditSessionRelay>()
    private val hostsToRelease = mutableListOf<TestHost>()

    /**
     * Runs [body] on the app's main thread and rethrows anything it threw on this one.
     *
     * The rethrow is the point of the wrapper: an exception escaping `runOnMainSync`'s block is delivered to the
     * main thread's uncaught handler and takes the whole app process down, which surfaces as an unrelated
     * "instrumentation run failed" rather than as the assertion that actually failed.
     */
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
        onMain { relaysToClose.forEach { it.close() } }
        relaysToClose.clear()
        hostsToRelease.distinctBy { System.identityHashCode(it) }.forEach { host ->
            // The handles a resync displaced are the host's to free (see [TestHost]) — releasing only
            // `host.handle` would leak one full parsed score per resync for the rest of the process.
            host.retired.forEach { SheetMusicJNI.nativeReleaseScore(it) }
            host.retired.clear()
            if (host.handle != 0L) SheetMusicJNI.nativeReleaseScore(host.handle)
        }
        hostsToRelease.clear()
    }

    private fun openRig(file: File, scoresDir: File, scoreId: String): Rig {
        val handle = SheetMusicJNI.nativeLoadScore(file.readBytes())
        assertNotEquals(0L, handle)
        lateinit var bridge: GeneratedEditBridging
        val host = TestHost(handle)
        lateinit var relay: EditSessionRelay
        var opened: OpenResult? = null
        onMain {
            // The view model is created on the main thread too: its constructor registers the observation callbacks
            // whose notifications are dispatched there.
            bridge = GeneratedEditBridging(EditorBridgeViewModel.create(EditorRoomFiles { _, _, _ -> }))
            relay = EditSessionRelay(bridge, host, RealEditNatives)
            relaysToClose.add(relay)
            hostsToRelease.add(host)
            opened = relay.open(file.path, scoresDir.path, scoreId)
        }
        assertEquals(OpenResult.OPENED, opened)
        return Rig(bridge, host, relay)
    }

    private fun stagedFixture(name: String): Pair<File, File> {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scoresDir = File(context.filesDir, "Scores").apply { mkdirs() }
        val file = File(scoresDir, "$name.mscz")
        context.assets.open("parity.mscz").use { input -> file.outputStream().use { input.copyTo(it) } }
        return file to scoresDir
    }

    @Test fun sessionsStayIdenticalThroughAScriptedEdit() {
        val (file, scoresDir) = stagedFixture("parity-scripted")
        val rig = openRig(file, scoresDir, "parity-scripted")
        val relay = rig.relay
        assertAgreed(rig, "after open")

        // Stand in for SP4's tap: select the first rest of the first bar by its ID.
        onMain { relay.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID()))) }
        // The selection is carried to the mirror through the generated observable projection rather than the
        // relay queue, and its native→Kotlin change notification is dispatched onto the main coroutine dispatcher
        // rather than applied inline, so wait for that dispatch to drain before reading it back.
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertNotNull("the first selection must have taken", rig.bridge.selectedItemFrame.value)
        assertAgreed(rig, "after the first selection")

        onMain {
            relay.armDuration(QUARTER)
            relay.inputPitch("C")
        }
        assertAgreed(rig, "after writing C")

        onMain {
            relay.inputPitch("E")
            relay.inputPitch("G")
        }
        assertAgreed(rig, "after writing E and G")

        onMain { relay.shiftPitch(1) }
        assertAgreed(rig, "after a semitone up")

        onMain {
            relay.armDuration(EIGHTH)
            relay.toggleArmedDot()
            relay.inputPitch("A")
        }
        assertAgreed(rig, "after a dotted eighth")

        onMain { relay.writeRest() }
        assertAgreed(rig, "after a rest")

        onMain { relay.deleteSelection() }
        assertAgreed(rig, "after a delete")

        // The undo/redo pass is what the main thread buys this test: driven from the instrumentation thread, the
        // relay's before/after reads raced the projection's posted updates and could see the op as refused.
        //
        // The two fingerprints bracketing the pass are not decoration. `assertAgreed` alone cannot tell a working
        // undo from an undo that did nothing at all on either side — both copies simply stay equal. That is the
        // exact shape of the bug this test is now positioned to catch, so the pass has to prove the score moved and
        // came back.
        val beforeUndo = mirrorFingerprint(rig)
        repeat(4) {
            onMain { relay.undo() }
            assertAgreed(rig, "after undo $it")
        }
        assertNotEquals("four undos must have moved the score", beforeUndo, mirrorFingerprint(rig))
        repeat(4) {
            onMain { relay.redo() }
            assertAgreed(rig, "after redo $it")
        }
        assertEquals("four redos must land back where the undos started", beforeUndo, mirrorFingerprint(rig))

        assertEquals("no resync should have been needed", 0, relay.resyncCount)
        assertTrue("the host should have been asked to redraw", rig.host.relayouts > 0)
        // The lifetime half of the same statement: no resync means no handle was ever superseded, so the host must
        // be holding exactly the one it opened with. A retirement appearing here would mean a swap happened that
        // `resyncCount` did not account for.
        assertTrue("a session with no resync must retire no handles", rig.host.retired.isEmpty())
    }

    /**
     * Closing a session does not revert the mirror, and SP3 saves nothing — so a second session parses the unedited
     * file while the handle still holds the edits. The fingerprint check in `open()` is what catches that, and this
     * is the test that fails if someone removes it as redundant.
     */
    @Test fun reopeningAfterAnUnsavedEditResyncsInsteadOfDiverging() {
        val (file, scoresDir) = stagedFixture("parity-reopen")
        val first = openRig(file, scoresDir, "parity-reopen")
        onMain {
            first.relay.selectItem(ScoreItemIDCodec.encode(ScoreItemID.Rest(firstRestID())))
            first.relay.armDuration(QUARTER)
            first.relay.inputPitch("C")
        }
        assertAgreed(first, "after the first session's edit")
        val editedFingerprint = SheetMusicJNI.nativeScoreFingerprint(first.host.handle)
        onMain { first.relay.close() }

        // Same handle, same (untouched) file: exactly what the Reader does when edit mode is re-entered.
        var opened: OpenResult? = null
        var localFingerprint = 0L
        onMain {
            val bridge = GeneratedEditBridging(EditorBridgeViewModel.create(EditorRoomFiles { _, _, _ -> }))
            val relay = EditSessionRelay(bridge, first.host, RealEditNatives)
            relaysToClose.add(relay)
            opened = relay.open(file.path, scoresDir.path, "parity-reopen")
            assertEquals("open must have resynced", 1, relay.resyncCount)
            localFingerprint = bridge.scoreFingerprint()
        }
        assertEquals(OpenResult.OPENED, opened)
        assertEquals(
            "the two copies must agree after the resync",
            localFingerprint,
            SheetMusicJNI.nativeScoreFingerprint(first.host.handle),
        )
        assertNotEquals(
            "the resync must have replaced the mirror's edited score, not adopted it",
            editedFingerprint,
            SheetMusicJNI.nativeScoreFingerprint(first.host.handle),
        )
        // The lifetime assertion this test exists to carry (SP4 Task 9). A resync loads a FRESH score and hands the
        // one it displaced to the host, which is the only party that may free it — so the single resync above must
        // have produced exactly one retirement, and that handle must not be the one still in use. Asserting the
        // count rather than merely draining it in [tearDown] is what makes this a gate: a relay that went back to
        // releasing the handle itself, or a host contract that stopped handing it over, both show up right here
        // instead of as a leak nobody measures.
        assertEquals("one resync must retire exactly one handle", 1, first.host.retired.size)
        assertNotEquals(
            "the retired handle must be the SUPERSEDED one, never the live one",
            first.host.handle,
            first.host.retired.single(),
        )
    }

    /**
     * Measures one fingerprint walk, so `FINGERPRINT_SAMPLE_EVERY` is chosen against a number, not a guess.
     *
     * The only test here that deliberately stays off the main thread: it drives no relay and no bridge — just fifty
     * `nativeScoreFingerprint` calls against a handle of its own — so the threading rule has nothing to say about
     * it, and pinning the main thread for fifty ~2ms walks would be inviting the watchdog for no gain.
     */
    @Test fun fingerprintWalkIsCheapEnoughToSample() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bytes = context.assets.open("parity.mscz").use { it.readBytes() }
        val handle = SheetMusicJNI.nativeLoadScore(bytes)
        val started = System.nanoTime()
        repeat(50) { SheetMusicJNI.nativeScoreFingerprint(handle) }
        val perWalkMicros = (System.nanoTime() - started) / 50 / 1_000
        android.util.Log.i("EditSessionParity", "stableFingerprint walk: ${perWalkMicros}us")
        SheetMusicJNI.nativeReleaseScore(handle)
        assertTrue("fingerprint walk unexpectedly slow: ${perWalkMicros}us", perWalkMicros < 2_000)
    }

    /** The mirror's digest, read on the relay's own thread like every other bridge/handle read here. */
    private fun mirrorFingerprint(rig: Rig): Long {
        var mirror = 0L
        onMain { mirror = SheetMusicJNI.nativeScoreFingerprint(rig.host.handle) }
        return mirror
    }

    private fun assertAgreed(rig: Rig, step: String) {
        var local = 0L
        var mirror = 0L
        onMain {
            local = rig.bridge.scoreFingerprint()
            mirror = SheetMusicJNI.nativeScoreFingerprint(rig.host.handle)
        }
        assertEquals(step, local, mirror)
    }

    private companion object {
        const val QUARTER = 3
        const val EIGHTH = 4

        /**
         * The fixture's first timed slot: `parity.mscz`'s staff 0 (part 0), measure 0, voice 0 opens with a
         * `Clef` (index 0), `KeySig` (index 1) and `TimeSig` (index 2) as voice elements before the bar's
         * whole-measure `Rest` at index 3 — confirmed against the raw MSCX and against
         * `SheetMusicMSCX/Decoders/MSCXDecoder+Voice.swift`, which appends one `VoiceElement` per `Clef`/`KeySig`/
         * `TimeSig`/`Rest` child and does NOT append one for `Tempo` (that is lifted onto `Score.systemMeasures`
         * instead, so it does not consume an element index).
         */
        fun firstRestID() = RestID(
            staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
            measureIndex = 0,
            voiceIndex = 0,
            elementIndex = 3,
        )
    }
}

package com.keynumber.folino.editor

import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.serialization.NoteIDCodec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [EditSessionRelay] — the policy that keeps Folino's authoritative score and ssm's mirror
 * identical, tested against fakes for [EditBridging], [EditNatives] and [EditSessionHost] so none of it needs a
 * device or JNI. Each case below pins a reason from the relay's own doc comments, not just its current shape.
 */
private class FakeBridge : EditBridging {
    var stamp = 7L
    var fingerprint = 100L
    var opened = false
    var revision = 0
    var appliedIntentCount = 0
    var encoded = byteArrayOf(1, 2, 3)
    var refuseUndo = false

    /**
     * When set, [undo] behaves like a violated `EditorBridge` contract: it moves the revision AND emits an intent
     * frame, the way a real undo never should. Exercises `replay()`'s drain-and-resync answer to that disagreement.
     */
    var strandFrameOnUndo = false

    /**
     * What the next [takePendingAudition] answers, then cleared — the shared core's `pendingAudition`, which every
     * op drains exactly once. Empty means "the core asked for no preview".
     */
    var pendingAudition: ByteArray = ByteArray(0)
    private val framesToEmit = mutableListOf<ByteArray>()

    /**
     * `flushSave` and `endSession` in the order the relay called them — the property `close()` has to get right.
     * The autosave fake appends to this same list, so the ordering across the two collaborators is one assertion.
     */
    val lifecycleLog = mutableListOf<String>()
    var flushes = 0

    override fun engineVersionStamp() = stamp
    override fun beginSession(path: String, dir: String, id: String) = true.also { opened = true }

    override fun endSession() {
        opened = false
        lifecycleLog.add("endSession")
    }

    override fun flushSave() {
        flushes += 1
        lifecycleLog.add("flushSave")
    }
    override fun scoreFingerprint() = fingerprint
    override fun encodeScore() = encoded
    override fun takeRelayFrames(): List<ByteArray> = framesToEmit.toList().also { framesToEmit.clear() }
    override fun takePendingAudition(): ByteArray = pendingAudition.also { pendingAudition = ByteArray(0) }
    override fun revision() = revision
    override fun appliedIntentCount() = appliedIntentCount

    override fun undo() {
        if (refuseUndo) return
        if (strandFrameOnUndo) willApply(1) else revision += 1
    }

    override fun redo() { revision += 1 }

    /** Stands in for one op that applies `count` intents — what a pad key does through the bridge. */
    override fun inputPitch(letter: String) = willApply(1)
    override fun deleteSelection() = willApply(1)

    /** Stands in for an op whose single user action applies more than one intent, e.g. a chord write. */
    override fun writeRest() = willApply(2)

    /** Stands in for an op that touches runtime state but never mutates the score — nothing to relay. */
    override fun setPlaybackActive(active: Boolean) {}

    /** Stands in for the unwind: it moves the score without emitting a single relay frame, which is the whole
     *  reason the relay reconciles a discard by fingerprint instead of by replaying frames. */
    var discards = 0
    override fun discardSessionEdits() { discards += 1 }
    override fun revertToOriginal() = false

    // The remaining `EditBridging` members: this file drives none of them, so empty bodies.
    override fun selectItem(bytes: ByteArray) {}
    override fun armDuration(kind: Int) {}
    override fun toggleArmedDot() {}
    override fun setArmedDots(dots: Int) {}
    override fun setSelectionDuration(kind: Int) {}
    override fun setSelectionDots(dots: Int) {}
    override fun toggleSelectionDot() {}
    override fun shiftPitch(semitones: Int) {}
    override fun shiftOctave(octaves: Int) {}
    override fun setAccidental(raw: String) {}
    override fun toggleAddToChord() {}
    override fun removeSelectedNoteFromChord() {}
    override fun toggleTie() {}
    override fun appendTiedNote() {}
    override fun createTuplet(actualNotes: Int) {}
    override fun removeTuplet() {}
    override fun selectPreviousElement() {}
    override fun selectNextElement() {}
    override fun setActiveVoice(voice: Int) {}

    private fun willApply(count: Int) {
        repeat(count) { framesToEmit.add(byteArrayOf(it.toByte())) }
        revision += count
        appliedIntentCount += count
    }
}

private class FakeNatives : EditNatives {
    var stamp = 7L
    var beginAnswer = true
    var fingerprint = 100L
    var loadAnswer = 42L
    var editUndoAnswer = true
    var editRedoAnswer = true

    /**
     * What `scoreFingerprint` answers once `loadScore` has replaced the mirror's score — i.e. after a resync.
     * A real reload of the authoritative bytes converges on the authoritative digest, so the default matches
     * [FakeBridge.fingerprint]; a test that wants a resync which completes and still disagrees moves it.
     */
    var fingerprintAfterLoad = 100L

    var begins = 0
    var ends = 0
    var loads = 0
    var editUndoCalls = 0
    var editRedoCalls = 0
    val applied = mutableListOf<ByteArray>()

    private val applyQueue = ArrayDeque<Boolean>()

    /** Answers `applyEditIntent` calls in order; once exhausted, every further call answers `true`. */
    var applyAnswers: List<Boolean> = emptyList()
        set(value) {
            applyQueue.clear()
            applyQueue.addAll(value)
        }

    override fun engineVersionStamp() = stamp

    override fun beginEditSession(handle: Long): Boolean {
        begins += 1
        return beginAnswer
    }

    override fun applyEditIntent(handle: Long, bytes: ByteArray): Boolean {
        applied.add(bytes)
        return if (applyQueue.isNotEmpty()) applyQueue.removeFirst() else true
    }

    override fun editUndo(handle: Long): Boolean {
        editUndoCalls += 1
        return editUndoAnswer
    }

    override fun editRedo(handle: Long): Boolean {
        editRedoCalls += 1
        return editRedoAnswer
    }

    override fun endEditSession(handle: Long) { ends += 1 }

    override fun scoreFingerprint(handle: Long) = fingerprint

    override fun loadScore(bytes: ByteArray): Long {
        loads += 1
        fingerprint = fingerprintAfterLoad
        return loadAnswer
    }
}

private class FakeHost : EditSessionHost {
    var handle = 1L
    var relayoutCount = 0
    val replacedHandles = mutableListOf<Long>()

    override fun scoreHandle() = handle

    override fun replaceScoreHandle(handle: Long) {
        replacedHandles.add(handle)
        this.handle = handle
    }

    override fun requestRelayout() { relayoutCount += 1 }
}

/** Records what the relay asked to have previewed, and how much had already been relayed when it asked. */
private class FakeAuditioning(private val natives: FakeNatives) : NoteAuditioning {
    val previewed = mutableListOf<NoteID>()

    /** `natives.applied.size` at each preview — what pins that the mirror is current BEFORE the note sounds. */
    val appliedWhenPreviewed = mutableListOf<Int>()

    override fun playPreview(noteId: NoteID) {
        previewed.add(noteId)
        appliedWhenPreviewed.add(natives.applied.size)
    }
}

/**
 * Records what the relay asks of its autosave.
 *
 * The cadence itself is [DebouncedAutosaveTest]'s subject; what is asserted here is that the relay asks at all, and
 * in the right order relative to the session's teardown — which is why the flush lands in the bridge's own
 * [FakeBridge.lifecycleLog] rather than in a second list of its own.
 */
private class FakeAutosave(private val lifecycleLog: MutableList<String>) : EditAutosave {
    var arms = 0
    var flushes = 0
    var cancels = 0

    override fun arm() { arms += 1 }

    override fun flushNow() {
        flushes += 1
        lifecycleLog.add("flushSave")
    }

    override fun cancel() { cancels += 1 }
}

/** Bundles one relay with its fakes so each test only states what it overrides. */
private class Fixture(
    val bridge: FakeBridge = FakeBridge(),
    val natives: FakeNatives = FakeNatives(),
    val host: FakeHost = FakeHost(),
) {
    val audition = FakeAuditioning(natives)
    val autosave = FakeAutosave(bridge.lifecycleLog)
    val relay = EditSessionRelay(bridge, host, natives, audition, autosave)

    fun open(): OpenResult = relay.open("/scores/a.ssm", "/scores", "a")
}

/** A `NoteID` distinct enough that a wrong one cannot pass for it. */
private fun sampleNoteID(elementIndex: Int = 3) = NoteID(
    staff = StaffAddress(partIndex = 0, staffIndexInPart = 0),
    measureIndex = 2,
    voiceIndex = 0,
    elementIndex = elementIndex,
    noteIndexInChord = 0,
)

class EditSessionRelayTest {
    // MARK: - The three open() gates

    @Test fun aVersionMismatchRefusesToOpen() {
        val f = Fixture(natives = FakeNatives().apply { stamp = 8L })

        val result = f.open()

        assertEquals(OpenResult.VERSION_SKEW, result)
        assertFalse(f.bridge.opened)
        assertEquals(0, f.natives.begins)
    }

    @Test fun aMissingHandleRefusesToOpen() {
        val f = Fixture(host = FakeHost().apply { handle = 0L })

        val result = f.open()

        assertEquals(OpenResult.NO_HANDLE, result)
        assertFalse(f.bridge.opened)
        assertEquals(0, f.natives.begins)
        assertEquals(0, f.relay.resyncCount)
    }

    @Test fun aMirrorThatRefusesClosesTheLocalSessionAgain() {
        val f = Fixture(natives = FakeNatives().apply { beginAnswer = false })

        val result = f.open()

        assertEquals(OpenResult.MIRROR_REFUSED, result)
        // beginSession() ran (opened flipped true), then endSession() closed it back down — the begin/end pairing.
        assertFalse(f.bridge.opened)
        assertEquals(1, f.natives.begins)
    }

    // MARK: - The open-time resync (§8.3's "normal second session")

    @Test fun openingOntoADivergedHandleResyncsBeforeTheFirstEdit() {
        val f = Fixture(natives = FakeNatives().apply { fingerprint = 999L })

        val result = f.open()

        assertEquals(OpenResult.OPENED, result)
        assertEquals(1, f.relay.resyncCount)
        // The single assertion that fails if `open()`'s trailing redraw stays conditional on `verifyOrResync()`
        // having found agreement: this is exactly the case where it did not, and a redraw is what tells the host
        // its handle was just swapped out from under it.
        assertEquals(1, f.host.relayoutCount)
    }

    @Test fun openingOntoAnAlreadyAgreeingHandleStillRedraws() {
        val f = Fixture()

        val result = f.open()

        assertEquals(OpenResult.OPENED, result)
        assertEquals(0, f.relay.resyncCount)
        assertEquals(1, f.host.relayoutCount)
    }

    @Test fun reopeningAnAlreadyOpenSessionClosesTheOldOneFirst() {
        val f = Fixture()
        f.open()
        val endsAfterFirstOpen = f.natives.ends

        f.open()

        assertEquals(endsAfterFirstOpen + 1, f.natives.ends)
    }

    // MARK: - Relaying an op

    @Test fun anAppliedIntentReachesTheMirrorOnceInOrder() {
        val f = Fixture()
        f.open()

        f.relay.writeRest() // FakeBridge.writeRest applies two intents in one op.

        assertEquals(2, f.natives.applied.size)
        assertArrayEquals(byteArrayOf(0), f.natives.applied[0])
        assertArrayEquals(byteArrayOf(1), f.natives.applied[1])
    }

    @Test fun anOpThatAppliesNothingRelaysNothing() {
        val f = Fixture()
        f.open()
        val relayoutsAfterOpen = f.host.relayoutCount

        f.relay.setPlaybackActive(true) // FakeBridge.setPlaybackActive applies no intents.

        assertEquals(0, f.natives.applied.size)
        assertEquals(0, f.relay.resyncCount)
        // relay() returns before requesting a redraw when there is nothing to relay.
        assertEquals(relayoutsAfterOpen, f.host.relayoutCount)
    }

    @Test fun aRefusedRelayResyncsImmediately() {
        val f = Fixture(natives = FakeNatives().apply { applyAnswers = listOf(false) })
        f.open()

        f.relay.inputPitch("C")

        assertEquals(1, f.relay.resyncCount)
        assertEquals(1, f.natives.loads)
        assertEquals(f.natives.loadAnswer, f.host.scoreHandle())
    }

    @Test fun fingerprintsAreComparedOnTheSamplingIntervalNotEveryEdit() {
        val f = Fixture()
        f.open()
        assertEquals(0, f.relay.resyncCount)

        // The check at open() saw the fingerprints agreeing; set the disagreement only now, so it is the
        // per-edit sampling — not the open-time check — under test.
        f.natives.fingerprint = 999L

        repeat(EditSessionRelay.FINGERPRINT_SAMPLE_EVERY - 1) { f.relay.inputPitch("C") }
        assertEquals(0, f.relay.resyncCount)

        f.relay.inputPitch("C")
        assertEquals(1, f.relay.resyncCount)
    }

    // MARK: - The audition the shared core asks for
    //
    // The core decides which note sounds and after which ops (`pendingAudition`); the relay is only the courier.
    // These pin the two things a courier can get wrong: dropping the request, and delivering it too early.

    @Test fun anOpThatAsksForAPreviewSoundsThatNote() {
        val f = Fixture()
        f.open()
        val noteId = sampleNoteID()
        f.bridge.pendingAudition = NoteIDCodec.encode(noteId)

        f.relay.inputPitch("C")

        assertEquals(listOf(noteId), f.audition.previewed)
    }

    @Test fun thePreviewSoundsOnlyAfterTheEditHasReachedTheMirror() {
        val f = Fixture()
        f.open()
        f.bridge.pendingAudition = NoteIDCodec.encode(sampleNoteID())

        f.relay.writeRest() // FakeBridge.writeRest applies TWO intents.

        // The engine resolves the NoteID against the mirror, so a note written by this very op does not exist
        // there until both frames have landed. Sounding at intent 0 or 1 is silence, not an early note.
        assertEquals(listOf(2), f.audition.appliedWhenPreviewed)
    }

    @Test fun anOpThatAppliesNothingStillSoundsItsPreview() {
        val f = Fixture()
        f.open()
        val noteId = sampleNoteID()
        f.bridge.pendingAudition = NoteIDCodec.encode(noteId)

        // A tap: it selects and asks for a preview without mutating the score, so it produces no relay frames.
        f.relay.selectItem(byteArrayOf(9))

        assertEquals(listOf(noteId), f.audition.previewed)
    }

    @Test fun anOpThatAsksForNoPreviewSoundsNothing() {
        val f = Fixture()
        f.open()

        f.relay.deleteSelection() // Applies an intent, and the core queues no audition for a delete.

        assertTrue(f.audition.previewed.isEmpty())
    }

    @Test fun aPreviewRequestIsDrainedEvenWhenItCannotBeSounded() {
        // A resync that cannot complete closes the session, and a closed session sounds nothing — but the request
        // must not survive into the next op, which would then preview a note the user never touched.
        val f = Fixture(
            bridge = FakeBridge().apply { encoded = ByteArray(0) },
            natives = FakeNatives().apply { applyAnswers = listOf(false) },
        )
        f.open()
        f.bridge.pendingAudition = NoteIDCodec.encode(sampleNoteID())

        f.relay.inputPitch("C")

        assertTrue(f.audition.previewed.isEmpty())
        assertEquals(ByteArray(0).size, f.bridge.pendingAudition.size)
    }

    // MARK: - undo/redo's own rules

    @Test fun undoChecksTheFingerprintUnconditionally() {
        val f = Fixture()
        f.open()

        f.natives.fingerprint = 999L // well under FINGERPRINT_SAMPLE_EVERY — undo must not wait for the interval.
        f.relay.undo()

        assertEquals(1, f.relay.resyncCount)
    }

    @Test fun aRefusedUndoOnTheLocalSideLeavesTheMirrorAlone() {
        val f = Fixture()
        f.open()

        f.bridge.refuseUndo = true
        f.natives.fingerprint = 999L // would resync immediately if undo() ever reached the mirror.
        f.relay.undo()

        assertEquals(0, f.natives.editUndoCalls)
        assertEquals(0, f.relay.resyncCount)
    }

    @Test fun anUndoThatStrandsAFrameResyncsInsteadOfCrashing() {
        val f = Fixture()
        f.open()

        // The contract `replay()` guards: an undo must move the revision WITHOUT emitting an intent. Break it.
        f.bridge.strandFrameOnUndo = true
        val resyncsBefore = f.relay.resyncCount

        f.relay.undo()

        assertEquals(resyncsBefore + 1, f.relay.resyncCount)
        // The mirror must never see the undo at all — the stranded frame is dropped, not replayed.
        assertEquals(0, f.natives.editUndoCalls)
        assertTrue(f.bridge.takeRelayFrames().isEmpty())
    }

    // MARK: - Discarding a session's edits

    @Test fun aDiscardReconcilesTheMirrorByFingerprintRatherThanByFrames() {
        // The unwind moves the authoritative score WITHOUT emitting intents, so the mirror is left holding the
        // edited score and only the fingerprint check can see it. Opening on an agreeing pair and moving the
        // mirror's digest afterwards is what puts the relay in exactly that position.
        val f = Fixture()
        f.open()
        val resyncsAfterOpen = f.relay.resyncCount
        f.natives.fingerprint = 999L

        f.relay.discardSessionEdits()

        assertEquals(1, f.bridge.discards)
        assertEquals(resyncsAfterOpen + 1, f.relay.resyncCount)
        assertEquals(0, f.natives.applied.size) // never replayed as intents
    }

    @Test fun aDiscardOnAnAgreeingMirrorCostsNoResync() {
        val f = Fixture()
        f.open()

        f.relay.discardSessionEdits()

        assertEquals(1, f.bridge.discards)
        assertEquals(0, f.relay.resyncCount)
    }

    @Test fun aDiscardDropsWhateverTheUnwindLeftBehind() {
        // Neither a stranded frame nor a stale audition may survive a discard: the next op would pick them up and
        // apply an edit — or sound a note — the user has just thrown away.
        val f = Fixture()
        f.open()
        f.bridge.inputPitch("C") // queues a frame the relay has not drained
        f.bridge.pendingAudition = NoteIDCodec.encode(sampleNoteID())

        f.relay.discardSessionEdits()

        assertTrue(f.bridge.takeRelayFrames().isEmpty())
        assertEquals(0, f.bridge.pendingAudition.size)
        assertTrue(f.audition.previewed.isEmpty())
    }

    @Test fun revertIsNotAvailableOnAndroidYet() {
        // Pins the placeholder honestly: the op exists so the UI's placement is settled, and answers false until
        // Android has an originals store (see the parity ledger).
        val f = Fixture()
        f.open()

        assertFalse(f.relay.revertToOriginal())
    }

    // MARK: - resync()'s own rules

    @Test fun aResyncDropsTheFramesItIsAboutToMakeRedundant() {
        val f = Fixture()
        f.open()

        // A frame lands on the bridge but is not drained through `relay()` — the situation `replay()`'s own
        // resync trigger below leaves behind, since it never calls `takeRelayFrames()` itself.
        f.bridge.inputPitch("stray")

        f.natives.editUndoAnswer = false
        f.relay.undo() // bridge.undo() moves the revision, the mirror refuses it, forcing a resync directly.
        assertEquals(1, f.relay.resyncCount)

        f.natives.applied.clear()
        f.relay.inputPitch("C")

        // Without the purge in resync(), the stray frame above would still be queued and apply a second time
        // alongside this op's own frame.
        assertEquals(1, f.natives.applied.size)
        assertArrayEquals(byteArrayOf(0), f.natives.applied[0])
    }

    @Test fun aResyncThatCannotEncodeClosesTheSession() {
        val f = Fixture(
            bridge = FakeBridge().apply { encoded = ByteArray(0) },
            natives = FakeNatives().apply { fingerprint = 999L },
        )

        val result = f.open()

        assertEquals(OpenResult.RESYNC_FAILED, result)
        assertEquals(1, f.relay.resyncCount)
        assertEquals(1, f.natives.ends)
        assertFalse(f.bridge.opened)

        val appliedBefore = f.natives.applied.size
        f.relay.inputPitch("C") // the session is closed; a subsequent op relays nothing.
        assertEquals(appliedBefore, f.natives.applied.size)
    }

    /**
     * The encode/load/reopen can all answer success and still leave the two copies different — a lossy encoder is
     * exactly what put this branch there once. A resync that does not converge is a failed resync.
     */
    @Test fun aResyncThatCompletesButDoesNotConvergeClosesTheSession() {
        val f = Fixture(
            natives = FakeNatives().apply {
                fingerprint = 999L
                fingerprintAfterLoad = 555L // the reload worked, and the copies still disagree.
            },
        )

        val result = f.open()

        assertEquals(OpenResult.RESYNC_FAILED, result)
        assertEquals(1, f.relay.resyncCount)
        assertFalse(f.bridge.opened)
        // One resync, not a recursive cascade: the convergence check must not route back through verifyOrResync().
        assertEquals(1, f.natives.loads)
    }

    // MARK: - close()

    @Test fun closingEndsBothSides() {
        val f = Fixture()
        f.open()

        f.relay.close()

        assertFalse(f.bridge.opened)
        assertEquals(1, f.natives.ends)

        f.relay.close() // safe to call twice
        assertEquals(1, f.natives.ends)
    }

    // MARK: - The autosave cadence

    @Test fun everyOpArmsTheAutosave() {
        val f = Fixture()
        f.open()

        f.relay.inputPitch("C")
        f.relay.deleteSelection()
        f.relay.undo()

        // The funnel is the choke point — iOS's op funnel arms unconditionally too, and for the same reason its own
        // doc gives: the timer must not be skippable for one op and not another.
        assertEquals(3, f.autosave.arms)
    }

    @Test fun anOpBeforeTheSessionOpensArmsNothing() {
        val f = Fixture()

        f.relay.inputPitch("C")

        assertEquals(0, f.autosave.arms)
    }

    @Test fun closeFlushesBeforeItEndsTheSession() {
        val f = Fixture()
        f.open()

        f.relay.close()

        // Ending first would drop whatever the debounce had not yet written: `endSession` takes the authoritative
        // session — and the score it holds — away.
        assertEquals(listOf("flushSave", "endSession"), f.bridge.lifecycleLog)
    }

    @Test fun aDiscardCancelsThePendingWriteRatherThanPerformingIt() {
        val f = Fixture()
        f.open()

        f.relay.inputPitch("C")
        f.relay.discardSessionEdits()

        // The armed write is for the score the user has just thrown away. The write-back of the UNWOUND score is
        // `EditorBridge.discardSessionEdits`'s own, on the Swift side.
        assertEquals(1, f.autosave.cancels)
        assertEquals(0, f.autosave.flushes)
    }

    @Test fun flushPendingSaveWritesWithoutEndingTheSession() {
        val f = Fixture()
        f.open()

        f.relay.flushPendingSave()

        assertEquals(1, f.autosave.flushes)
        assertTrue("onPause must not end the session it flushed", f.bridge.opened)
    }

    @Test fun flushPendingSaveBeforeTheSessionOpensDoesNothing() {
        val f = Fixture()

        f.relay.flushPendingSave()

        assertEquals(0, f.autosave.flushes)
    }
}

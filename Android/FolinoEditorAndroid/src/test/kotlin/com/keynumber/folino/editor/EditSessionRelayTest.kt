package com.keynumber.folino.editor

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    private val framesToEmit = mutableListOf<ByteArray>()

    override fun engineVersionStamp() = stamp
    override fun beginSession(path: String, dir: String, id: String) = true.also { opened = true }
    override fun endSession() { opened = false }
    override fun scoreFingerprint() = fingerprint
    override fun encodeScore() = encoded
    override fun takeRelayFrames(): List<ByteArray> = framesToEmit.toList().also { framesToEmit.clear() }
    override fun revision() = revision
    override fun appliedIntentCount() = appliedIntentCount
    override fun undo() { if (!refuseUndo) revision += 1 }
    override fun redo() { revision += 1 }

    /** Stands in for one op that applies `count` intents — what a pad key does through the bridge. */
    override fun inputPitch(letter: String) = willApply(1)
    override fun deleteSelection() = willApply(1)

    /** Stands in for an op whose single user action applies more than one intent, e.g. a chord write. */
    override fun writeRest() = willApply(2)

    /** Stands in for an op that touches runtime state but never mutates the score — nothing to relay. */
    override fun setPlaybackActive(active: Boolean) {}

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

    var begins = 0
    var ends = 0
    var loads = 0
    var releases = 0
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
        return loadAnswer
    }

    override fun releaseScore(handle: Long) { releases += 1 }
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

/** Bundles one relay with its fakes so each test only states what it overrides. */
private class Fixture(
    val bridge: FakeBridge = FakeBridge(),
    val natives: FakeNatives = FakeNatives(),
    val host: FakeHost = FakeHost(),
) {
    val relay = EditSessionRelay(bridge, host, natives)

    fun open(): OpenResult = relay.open("/scores/a.ssm", "/scores", "a")
}

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
}

package com.keynumber.folino.editor

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [ConfinedEditSessionOps] — the wrapper that moves the editing session off Compose's main thread.
 *
 * Two properties decide whether it is safe, and they pull in opposite directions, so both are pinned here:
 *
 * - **Order is never lost.** The relay's whole design rests on one thread performing op-then-drain pairs without
 *   interleaving; a wrapper that let two ops overlap would break it more thoroughly than the main thread ever did.
 * - **The calls that a caller depends on having finished actually block.** `open` has to answer, and `close` and
 *   `flushPendingSave` exist precisely to complete before something goes away.
 */
class ConfinedEditSessionOpsTest {

    /** Records the calling thread of every op, and blocks on demand so overlap would be detectable. */
    private class RecordingOps(private val openResult: OpenResult = OpenResult.OPENED) : EditSessionOps {
        val calls = mutableListOf<String>()
        val threads = mutableListOf<String>()
        var gate: CountDownLatch? = null
        @Volatile var concurrent = false
        private var inFlight = false

        private fun record(name: String) {
            synchronized(this) {
                if (inFlight) concurrent = true
                inFlight = true
            }
            calls += name
            threads += Thread.currentThread().name
            gate?.await()
            synchronized(this) { inFlight = false }
        }

        override fun open(scorePath: String, scoresDirectory: String, scoreId: String): OpenResult {
            record("open")
            return openResult
        }

        override fun close() = record("close")
        override fun flushPendingSave() = record("flushPendingSave")
        override fun revertToOriginal(): Boolean {
            record("revertToOriginal")
            return false
        }

        override fun selectItem(bytes: ByteArray) = record("selectItem")
        override fun inputPitch(letter: String) = record("inputPitch($letter)")
        override fun deleteSelection() = record("deleteSelection")
        override fun writeRest() = record("writeRest")
        override fun armDuration(kind: Int) = record("armDuration")
        override fun toggleArmedDot() = record("toggleArmedDot")
        override fun setArmedDots(dots: Int) = record("setArmedDots")
        override fun setSelectionDuration(kind: Int) = record("setSelectionDuration")
        override fun setSelectionDots(dots: Int) = record("setSelectionDots")
        override fun toggleSelectionDot() = record("toggleSelectionDot")
        override fun shiftPitch(semitones: Int) = record("shiftPitch")
        override fun shiftOctave(octaves: Int) = record("shiftOctave")
        override fun setAccidental(raw: String) = record("setAccidental")
        override fun toggleAddToChord() = record("toggleAddToChord")
        override fun removeSelectedNoteFromChord() = record("removeSelectedNoteFromChord")
        override fun toggleTie() = record("toggleTie")
        override fun appendTiedNote() = record("appendTiedNote")
        override fun createTuplet(actualNotes: Int) = record("createTuplet")
        override fun removeTuplet() = record("removeTuplet")
        override fun selectPreviousElement() = record("selectPreviousElement")
        override fun selectNextElement() = record("selectNextElement")
        override fun setActiveVoice(voice: Int) = record("setActiveVoice")
        override fun setPlaybackActive(active: Boolean) = record("setPlaybackActive")
        override fun discardSessionEdits() = record("discardSessionEdits")
        override fun undo() = record("undo")
        override fun redo() = record("redo")
    }

    private fun fixture(delegate: RecordingOps): Pair<ConfinedEditSessionOps, java.util.concurrent.ExecutorService> {
        val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "test-edit") }
        return ConfinedEditSessionOps(delegate, executor) to executor
    }

    @Test fun opsRunOnTheConfinedThreadRatherThanTheCaller() {
        val delegate = RecordingOps()
        val (ops, executor) = fixture(delegate)

        ops.inputPitch("C")
        ops.close() // blocks, so by the time it returns the fire-and-forget op above has run too

        assertEquals(listOf("inputPitch(C)", "close"), delegate.calls)
        val caller = Thread.currentThread().name
        assertTrue(delegate.threads.all { it == "test-edit" })
        assertNotEquals(caller, delegate.threads.first())
        executor.shutdown()
    }

    @Test fun orderIsPreservedAcrossFireAndForgetOps() {
        val delegate = RecordingOps()
        val (ops, executor) = fixture(delegate)

        ops.inputPitch("C")
        ops.deleteSelection()
        ops.undo()
        ops.redo()
        ops.close()

        assertEquals(
            listOf("inputPitch(C)", "deleteSelection", "undo", "redo", "close"),
            delegate.calls,
        )
        assertFalse("two ops must never overlap", delegate.concurrent)
        executor.shutdown()
    }

    @Test fun openBlocksAndAnswers() {
        val delegate = RecordingOps(openResult = OpenResult.VERSION_SKEW)
        val (ops, executor) = fixture(delegate)

        val result = ops.open("/a.mscz", "/scores", "id")

        // `EditSessionController.begin` writes `isEditing` from this answer synchronously; it cannot be a promise.
        assertEquals(OpenResult.VERSION_SKEW, result)
        assertEquals(listOf("open"), delegate.calls)
        executor.shutdown()
    }

    @Test fun flushPendingSaveBlocksUntilTheWriteIsDone() {
        val delegate = RecordingOps()
        val (ops, executor) = fixture(delegate)

        ops.inputPitch("C")
        ops.flushPendingSave()

        // It exists to beat process death on `onPause`, so returning before the write lands would defeat it.
        assertEquals(listOf("inputPitch(C)", "flushPendingSave"), delegate.calls)
        executor.shutdown()
    }

    @Test fun closeBlocksSoNothingCanReleaseTheBridgeUnderIt() {
        val delegate = RecordingOps()
        val (ops, executor) = fixture(delegate)
        // Queue work that takes a while, then close: close must wait for all of it.
        val gate = CountDownLatch(1)
        delegate.gate = gate
        val worker = Thread {
            ops.inputPitch("C")
            gate.countDown()
        }
        worker.start()
        worker.join()

        ops.close()

        assertEquals(listOf("inputPitch(C)", "close"), delegate.calls)
        executor.shutdown()
        assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
    }

    @Test fun aThrowFromAnAwaitedOpReachesTheCallerAsItself() {
        val executor = Executors.newSingleThreadExecutor()
        val ops = ConfinedEditSessionOps(
            object : EditSessionOps by RecordingOps() {
                override fun close(): Unit = throw IllegalStateException("boom")
            },
            executor,
        )

        val thrown = runCatching { ops.close() }.exceptionOrNull()

        // Not an ExecutionException wrapper: a failure that changes shape on the way out is a failure nobody
        // recognises at the call site.
        assertTrue("got $thrown", thrown is IllegalStateException)
        assertEquals("boom", thrown?.message)
        executor.shutdown()
    }
}

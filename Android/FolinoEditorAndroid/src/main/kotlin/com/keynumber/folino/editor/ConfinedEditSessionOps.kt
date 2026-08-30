package com.keynumber.folino.editor

import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService

/**
 * Runs the editing session on one dedicated thread instead of Compose's main thread.
 *
 * ## Why
 *
 * A save encodes the whole score, and on a Pixel 8a that measured 160-230 ms even for a small one
 * (`EditPersistenceTest`). Taken on the main thread — which is where every op ran, since `EditorBridge` is driven
 * synchronously — that is a visible freeze two seconds after the user stops typing.
 *
 * The bridge cannot simply move the save to a background thread: it holds a non-`Sendable` `EditorSessionCore` and
 * its ops are op-then-drain PAIRS (`inputPitch` then `takeRelayFrames`) that must not interleave. So the answer is
 * not to make the bridge concurrent but to move the ONE thread it runs on. [EditSessionRelay]'s own threading note
 * says exactly this — "do not move these onto a coroutine dispatcher without giving the bridge a lock first" — and a
 * single-thread executor satisfies that condition by construction rather than by a lock.
 *
 * Nothing downstream had to change for this. [EditSessionHost]'s three methods were already thread-agnostic:
 * `scoreHandle` reads a `StateFlow`, `requestRelayout` writes one, and `replaceScoreHandle` takes the Reader's own
 * `layoutMutex` with its own `runBlocking` — which is now called off the main thread rather than on it, which is
 * strictly better. The audition seam reads a `StateFlow` and calls the audio engine.
 *
 * ## Which calls block
 *
 * Fire-and-forget for the ops, because that is the whole point, and the single-thread executor keeps them in order.
 * Blocking for the four calls whose caller genuinely depends on completion:
 *
 * - [open] has to answer — `EditSessionController.begin` writes `isEditing` from its result synchronously.
 * - [close] must finish before anything can release the native bridge under it. It is also the moment the session's
 *   last save is flushed, and it happens while a screen is already going away, so the wait is invisible.
 * - [flushPendingSave] exists to beat process death on `onPause`; returning before the write landed would defeat it.
 * - [revertToOriginal] answers a Boolean the UI acts on.
 *
 * The executor is the caller's to create and to shut down, and it must be single-threaded — see [EditSessionRelay].
 */
class ConfinedEditSessionOps(
    private val delegate: EditSessionOps,
    private val executor: ExecutorService,
) : EditSessionOps {

    private fun post(op: () -> Unit) {
        executor.execute(op)
    }

    /**
     * Runs [op] on the confined thread and waits.
     *
     * Unwraps [ExecutionException] so a failure arrives at the call site as itself: an exception that changes shape
     * on the way out of a wrapper is one nobody recognises, and every caller of this path is teardown code where a
     * misread failure is the difference between a lost save and a crash report that names it.
     */
    private fun <T> await(op: () -> T): T =
        try {
            executor.submit(Callable { op() }).get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        }

    // MARK: - Blocking

    override fun open(
        scorePath: String,
        scoresDirectory: String,
        scoreId: String,
        carriedItem: ByteArray,
    ): OpenResult = await { delegate.open(scorePath, scoresDirectory, scoreId, carriedItem) }

    /** A plain read of the delegate's flow — no hop. It is a `StateFlow` the delegate writes on THIS executor and
     * Compose collects on the main thread, which is what a `StateFlow` is for; confining the read would only add
     * a blocking round trip to a value that is already published safely. */
    override val hasEditTarget get() = delegate.hasEditTarget

    override fun close() = await { delegate.close() }

    override fun flushPendingSave() = await { delegate.flushPendingSave() }

    override fun revertToOriginal(): Boolean = await { delegate.revertToOriginal() }

    // MARK: - Fire and forget
    //
    // One line each, and nothing may branch — the same rule the relay and the controller carry, for the same
    // reason: a decision here is a rule Android would have and iOS would not.

    override fun selectItem(bytes: ByteArray) = post { delegate.selectItem(bytes) }
    override fun inputPitch(letter: String) = post { delegate.inputPitch(letter) }
    override fun deleteSelection() = post { delegate.deleteSelection() }
    override fun writeRest() = post { delegate.writeRest() }
    override fun armDuration(kind: Int) = post { delegate.armDuration(kind) }
    override fun toggleArmedDot() = post { delegate.toggleArmedDot() }
    override fun setArmedDots(dots: Int) = post { delegate.setArmedDots(dots) }
    override fun setSelectionDuration(kind: Int) = post { delegate.setSelectionDuration(kind) }
    override fun setSelectionDots(dots: Int) = post { delegate.setSelectionDots(dots) }
    override fun toggleSelectionDot() = post { delegate.toggleSelectionDot() }
    override fun shiftPitch(semitones: Int) = post { delegate.shiftPitch(semitones) }
    override fun shiftOctave(octaves: Int) = post { delegate.shiftOctave(octaves) }
    override fun setAccidental(raw: String) = post { delegate.setAccidental(raw) }
    override fun toggleAddToChord() = post { delegate.toggleAddToChord() }
    override fun removeSelectedNoteFromChord() = post { delegate.removeSelectedNoteFromChord() }
    override fun toggleTie() = post { delegate.toggleTie() }
    override fun appendTiedNote() = post { delegate.appendTiedNote() }
    override fun createTuplet(actualNotes: Int) = post { delegate.createTuplet(actualNotes) }
    override fun removeTuplet() = post { delegate.removeTuplet() }
    override fun selectPreviousElement() = post { delegate.selectPreviousElement() }
    override fun selectNextElement() = post { delegate.selectNextElement() }
    override fun setActiveVoice(voice: Int) = post { delegate.setActiveVoice(voice) }
    override fun setPlaybackActive(active: Boolean) = post { delegate.setPlaybackActive(active) }
    override fun discardSessionEdits() = post { delegate.discardSessionEdits() }
    override fun undo() = post { delegate.undo() }
    override fun redo() = post { delegate.redo() }
}

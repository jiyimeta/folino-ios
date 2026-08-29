package com.keynumber.folino.editor

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * When the session's pending edits get written.
 *
 * An interface for the same reason [EditNatives] and [EditBridging] are ones: [EditSessionRelay] is the piece under
 * test, and its cadence obligations — arm on every op, flush before the session ends, cancel on a discard — are
 * assertable without a clock only if the thing it drives can be recorded. The shipping implementation is
 * [DebouncedAutosave].
 */
interface EditAutosave {
    /** (Re)starts the quiet period. Called once per op, from the relay's funnel. */
    fun arm()

    /** Writes now, synchronously, and drops whatever was armed. */
    fun flushNow()

    /** Drops the pending write without performing it. */
    fun cancel()
}

/**
 * The editing session's autosave cadence — Android's half of what iOS's `EditorViewModel.scheduleAutosave` does.
 *
 * The policy of a save (where, in what format, what the row becomes afterwards) is the shared
 * `EditorSessionCore.performSave`; what lives here is only the timer, which belongs where the run loop is. The
 * `FolinoEditorJNI` image has no run loop at all, so this is the piece that cannot be shared.
 *
 * **[save] runs on the caller's thread — the main thread.** It reaches into `EditorBridge`, which is single-threaded
 * by construction: every op runs synchronously on the main thread and mutates the same non-`Sendable`
 * `EditorSessionCore`. Moving the write to `Dispatchers.IO` would be a data race against the next pad tap, not a
 * responsiveness win. The quiet period is what keeps the encode off the typing path; [flushNow] is the one place the
 * cost is taken deliberately.
 *
 * @param delayMillis the quiet period after the last edit. 2 s, matching iOS's `scheduleAutosave` and the Reader's
 *   annotation debounce.
 */
class DebouncedAutosave(
    private val scope: CoroutineScope,
    private val delayMillis: Long = 2_000L,
    private val save: () -> Unit,
) : EditAutosave {
    private var pending: Job? = null

    override fun arm() {
        pending?.cancel()
        pending = scope.launch {
            delay(delayMillis)
            save()
        }
    }

    /**
     * Synchronous rather than launched: every caller is about to do something the write must precede — end the
     * session, discard the edits, or let the process be backgrounded — and a coroutine queued behind that is a
     * coroutine that may never run. The Swift side answers "nothing to do" when the session is clean, so calling it
     * unconditionally is correct and keeps dirtiness tracked in exactly one place.
     */
    override fun flushNow() {
        pending?.cancel()
        pending = null
        save()
    }

    /** For a discard, which is about to make the pending write wrong. */
    override fun cancel() {
        pending?.cancel()
        pending = null
    }
}

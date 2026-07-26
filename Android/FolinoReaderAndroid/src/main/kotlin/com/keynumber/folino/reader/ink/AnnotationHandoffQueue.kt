package com.keynumber.folino.reader.ink

/**
 * Bookkeeping for the wet→dry handoff of finished ink strokes.
 *
 * `InProgressStrokesView` keeps drawing a stroke after `finishStroke`: the finished stroke moves into its
 * internal `FinishedShapesView`, which renders it until the client calls `removeFinishedStrokes`. That
 * retention window exists precisely so the client can get the stroke onto its own (dry) layer first —
 * removing it inside the finished-strokes listener leaves NOBODY drawing the stroke until the dry layer
 * catches up. Folino's commit path is asynchronous and multi-hop (off-main JNI capture → VM state →
 * off-main placement recompute → `View.invalidate`), so that gap is several frames: the ink visibly blinks
 * out the instant the finger lifts and pops back a moment later.
 *
 * This queue closes the gap. [retain] parks a finished stroke's removal callback; [onDryRendered] fires the
 * removals whose committed drawing the dry layer has now painted; [releaseAll] drops everything when the
 * retained copies would go stale — a retained stroke is frozen at the `strokeToViewTransform` captured at
 * handoff, so it does not follow a later zoom and must be retired rather than left misplaced.
 *
 * Main-thread confined: every entry point is called from the UI thread.
 */
internal class AnnotationHandoffQueue<T : Any> {
    private class Entry<T : Any>(private val onRelease: () -> Unit) {
        var drawing: T? = null
        private var released = false

        fun release() {
            if (released) return
            released = true
            onRelease()
        }
    }

    private val entries = mutableListOf<Entry<T>>()

    /** Strokes the wet layer is still rendering on our behalf. */
    val retainedCount: Int get() = entries.size

    /**
     * Park [release] — the callback that hands a just-finished stroke back to androidx.ink for removal —
     * until the dry layer has painted its committed counterpart. Returns the completion the capture path
     * invokes with its result: a `null` drawing (the stroke didn't anchor, so nothing will ever render it)
     * releases the wet copy at once.
     */
    fun retain(release: () -> Unit): (T?) -> Unit {
        val entry = Entry<T>(release)
        entries += entry
        return { drawing ->
            if (drawing == null) {
                entries.remove(entry)
                entry.release()
            } else {
                entry.drawing = drawing
            }
        }
    }

    /**
     * The dry layer has painted a frame built from [rendered] — drop the wet copies it now covers. Compared
     * by identity: the committed wire handed back by the capture path is the very instance appended to the
     * layer, so identity is exact where value equality could match a look-alike drawing.
     */
    fun onDryRendered(rendered: List<T>) {
        val covered = mutableListOf<Entry<T>>()
        entries.removeAll { entry ->
            val drawing = entry.drawing ?: return@removeAll false
            val isCovered = rendered.any { it === drawing }
            if (isCovered) covered += entry
            isCovered
        }
        // Released after the list is settled so a re-entrant call can't observe a half-mutated queue.
        covered.forEach { it.release() }
    }

    /** Drop every retained copy now, committed or not. */
    fun releaseAll() {
        val all = entries.toList()
        entries.clear()
        all.forEach { it.release() }
    }
}

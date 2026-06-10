package com.keynumber.folino.screenshot.fixtures

import java.util.concurrent.atomic.AtomicBoolean

// Cross-`setContent` readiness latch for scenes whose content arrives asynchronously (e.g. the Reader,
// which parses + lays out a score on background dispatchers that Compose's `waitForIdle()` does NOT
// track). The capture harness resets this before composing and then `waitUntil`s for it to flip true,
// so the bitmap is taken only after the score has actually rendered. Synchronous scenes (Library) leave
// it at its reset default and the harness's bounded wait falls through immediately via the timeout.
object SceneReady {
    private val ready = AtomicBoolean(false)
    // True for scenes that opt into the gate (so the harness knows to actually wait vs. skip).
    private val gated = AtomicBoolean(false)

    /** Called by the harness before each capture. */
    fun reset() {
        ready.set(false)
        gated.set(false)
    }

    /** A scene marks itself as async-gated (the harness will block on [isReady]). */
    fun markGated() {
        gated.set(true)
    }

    /** The scene signals its content is fully rendered. */
    fun signalReady() {
        ready.set(true)
    }

    /** Whether the harness should wait for readiness for this capture. */
    fun isGated(): Boolean = gated.get()

    /** Whether the gated scene's content is ready. */
    fun isReady(): Boolean = ready.get()
}

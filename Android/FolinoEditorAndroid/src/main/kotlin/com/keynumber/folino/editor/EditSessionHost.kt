package com.keynumber.folino.editor

/**
 * The three things the relay needs from whoever owns the ssm score handle.
 *
 * An interface rather than a direct `ReaderViewModel` reference for two reasons: it keeps this module independent of
 * `:FolinoReaderAndroid` (which will depend on THIS one when SP4 wires the UI), and it lets the device parity test
 * drive the relay with nothing but a handle and no Reader at all.
 */
interface EditSessionHost {
    /** The handle the mirror session lives beside. `0` when there is none. */
    fun scoreHandle(): Long

    /**
     * Swaps in a fresh handle after a resync. Everything downstream of the handle — MIDI render, timeline, cursor,
     * parts/staves — keys off it, so this is the one moment in a session when all of that re-fires. It is also why
     * a resync is the recovery path and not the mechanism.
     *
     * **The implementation must drop every use of the PREVIOUS handle synchronously, before returning.** The relay
     * calls `nativeReleaseScore(stale)` on the line after this one: the old handle is a freed native score from the
     * moment this method returns, and anything still holding it — a render pass queued onto another thread, a
     * coroutine that will read it on the next frame, a cursor job posted to the main looper — is a use-after-free,
     * not a stale read. Tearing down asynchronously and "letting it settle" is therefore not an option here. If the
     * teardown genuinely cannot be synchronous, the implementation must take its own reference to the handle's
     * lifetime rather than leave the window open.
     */
    fun replaceScoreHandle(handle: Long)

    /** Asks the host to recompute the layout and redraw. Called once per relayed op, after the mirror is current. */
    fun requestRelayout()
}

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
     * **The host owns both handles' lifetimes; the relay frees neither.** An earlier revision of this contract asked
     * the implementation to drop every use of the PREVIOUS handle synchronously before returning, because the relay
     * released it on the very next line. SP4 Task 9 established that no Android host can honor that: `ReaderViewModel`
     * can prove it for the layout calls (they take `layoutMutex` and re-check the published handle), but the score is
     * also handed to the audio engine — `ReaderAudioViewModel.preparePlayback` caches the raw value AND passes it to
     * a bound `MediaSessionService` that deliberately outlives the Reader, so nothing on the Kotlin side can make the
     * engine let go of it synchronously, or observe when it has. The escape hatch this doc used to offer ("take its
     * own reference to the handle's lifetime") is therefore the only reachable answer, and it is now the rule rather
     * than the fallback: the relay never calls `nativeReleaseScore`, and the superseded handle stays alive until the
     * process ends. See `ReaderViewModel.replaceScoreHandle` for why that is the same bounded native leak this
     * codebase already accepts for the score the playback engine holds.
     *
     * What the implementation still owes is narrower, and is about correctness rather than safety: once this returns,
     * anything that resolves positions against the score — hit-tests, caret rects, layout — must be reading the NEW
     * handle, because the relay's next fingerprint check compares that one. A holder left on the previous handle is a
     * stale read of a still-valid score, never a use-after-free.
     */
    fun replaceScoreHandle(handle: Long)

    /** Asks the host to recompute the layout and redraw. Called once per relayed op, after the mirror is current. */
    fun requestRelayout()
}

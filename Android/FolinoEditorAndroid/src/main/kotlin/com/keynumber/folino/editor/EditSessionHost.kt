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
     * than the fallback: the relay never calls `nativeReleaseScore`.
     *
     * **Taking a reference means ending it, and that half is the implementation's to build.** "Never freed" is not a
     * correct reading of this contract and was briefly the shipped one: a resync is an automatic recovery path that
     * can repeat inside a single session, so retaining every superseded handle for the process leaks one full parsed
     * `Score` per resync. The implementation therefore has to hold each displaced handle until it can show no holder
     * is left, and free it then. `ReaderViewModel` does this by draining under the same lock its layout calls take,
     * from a point after the swap has already driven a layout, and by asking the audio side (which is the holder it
     * cannot reason about from the outside) whether it still has the pointer — see `retiredHandlesToRelease` and
     * `ReaderAudioViewModel.isPreparedWith` for the shape that takes.
     *
     * What the implementation still owes beyond that is about correctness rather than safety: once this returns,
     * anything that resolves positions against the score — hit-tests, caret rects, layout — must be reading the NEW
     * handle, because the relay's next fingerprint check compares that one. Until the implementation frees it, a
     * holder left on the previous handle is a stale read of a still-valid score rather than a use-after-free — which
     * is what buys the room to drain deliberately instead of synchronously, and is not a licence to leave it forever.
     */
    fun replaceScoreHandle(handle: Long)

    /** Asks the host to recompute the layout and redraw. Called once per relayed op, after the mirror is current. */
    fun requestRelayout()
}

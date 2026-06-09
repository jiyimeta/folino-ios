package com.keynumber.folino.reader

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-scoped bridge between the Reader screen (FolinoReaderAndroid) and the Activity (app),
 * which can't see each other's view models directly. The Reader publishes PiP *eligibility*,
 * playback state, staff count, and transport callbacks while it is on screen; `MainActivity`
 * reads them to build `PictureInPictureParams` and to route in-window RemoteAction taps.
 *
 * Android PiP keeps the Activity alive, so a process singleton is the right scope. Callbacks and
 * flags are cleared via [reset] when the Reader leaves composition to avoid stale transport hooks.
 */
object ReaderPipController {
    private val _isInPipMode = MutableStateFlow(false)
    /** True while the system shows the Activity in a PiP window. Set by `MainActivity`. */
    val isInPipMode: StateFlow<Boolean> = _isInPipMode.asStateFlow()
    fun setInPipMode(value: Boolean) { _isInPipMode.value = value }

    private val _eligible = MutableStateFlow(false)
    /** True when the Reader is on screen, PiP is enabled, and playback is playing. */
    val eligible: StateFlow<Boolean> = _eligible.asStateFlow()
    fun setEligible(value: Boolean) { _eligible.value = value }

    private val _isPlaying = MutableStateFlow(false)
    /** Drives the in-window play/pause glyph. */
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    fun setPlaying(value: Boolean) { _isPlaying.value = value }

    private val _staffCount = MutableStateFlow(2)
    /** Total staff count of the open score; drives the PiP window aspect ratio. */
    val staffCount: StateFlow<Int> = _staffCount.asStateFlow()
    fun setStaffCount(value: Int) { _staffCount.value = value }

    /** Toggle play/pause on the live engine. Registered by the Reader; invoked by the receiver. */
    @Volatile var onTogglePlayPause: (() -> Unit)? = null

    /** Seek by a signed delta in seconds (±10s), clamped by the Reader. */
    @Volatile var onSkip: ((Double) -> Unit)? = null

    /** Clear transport hooks + eligibility when the Reader leaves the screen. */
    fun reset() {
        onTogglePlayPause = null
        onSkip = null
        _eligible.value = false
        _isPlaying.value = false
    }
}

/** Implemented by the host Activity so the Reader's toolbar button can enter PiP immediately. */
interface PipHost {
    fun enterPipNow()
}

/** Walk the context wrappers to the hosting Activity (for the toolbar PiP button). */
fun Context.findActivity(): Activity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

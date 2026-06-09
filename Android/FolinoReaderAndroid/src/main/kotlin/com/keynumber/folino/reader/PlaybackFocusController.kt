package com.keynumber.folino.reader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import androidx.core.content.ContextCompat

/**
 * Owns Android playback-interruption policy for the Reader's foreground playback service: audio-focus
 * arbitration with other apps and the "becoming noisy" (headphone / Bluetooth unplug) broadcast.
 *
 * The custom [EnginePlayer] is a [androidx.media3.common.SimpleBasePlayer], so — unlike `ExoPlayer` — it gets
 * none of media3's automatic focus / noisy handling. This class supplies it, mirroring the AVAudioSession
 * interruption + route-change behavior on iOS.
 *
 * Two callbacks drive the engine: [onPause] silences it while preserving any intent to resume, and [onResume]
 * starts it again. Focus is acquired before playback starts ([acquire]) and abandoned when it fully stops
 * ([release]). The engine is resumed automatically only when we paused it ourselves for a *transient* focus
 * loss (a phone call, a transient duck-or-pause from another app) — never after a permanent loss or an unplug.
 */
class PlaybackFocusController(
    context: Context,
    private val onPause: () -> Unit,
    private val onResume: () -> Unit,
) {
    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var resumeOnFocusGain = false
    private var noisyRegistered = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnFocusGain = false
                onPause()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                resumeOnFocusGain = true
                onPause()
            }
            AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnFocusGain) {
                resumeOnFocusGain = false
                onResume()
            }
        }
    }

    private val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
        )
        // Pause (don't duck) on a transient loss: a notification chime shouldn't quietly lower the
        // volume of a score the user is practising along to — a clean pause/resume is less jarring.
        .setWillPauseWhenDucked(true)
        .setOnAudioFocusChangeListener(focusListener)
        .build()

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                resumeOnFocusGain = false
                onPause()
            }
        }
    }

    /** Request audio focus and start listening for unplug, before playback begins. Returns false if denied. */
    fun acquire(): Boolean {
        registerNoisy()
        return audioManager.requestAudioFocus(focusRequest) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /** Abandon focus and stop listening for unplug, when playback fully stops. Idempotent. */
    fun release() {
        resumeOnFocusGain = false
        unregisterNoisy()
        audioManager.abandonAudioFocusRequest(focusRequest)
    }

    private fun registerNoisy() {
        if (noisyRegistered) return
        ContextCompat.registerReceiver(
            appContext,
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        noisyRegistered = true
    }

    private fun unregisterNoisy() {
        if (!noisyRegistered) return
        appContext.unregisterReceiver(noisyReceiver)
        noisyRegistered = false
    }
}

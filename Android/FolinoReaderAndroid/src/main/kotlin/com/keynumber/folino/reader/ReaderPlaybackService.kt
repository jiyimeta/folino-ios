package com.keynumber.folino.reader

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

private const val NOTIFICATION_ID = 1001
private const val CHANNEL_ID = "folino_playback"
private const val CHANNEL_NAME = "Playback"

class ReaderPlaybackService : MediaSessionService() {

    private lateinit var engine: AndroidPlaybackEngine
    private lateinit var focusController: PlaybackFocusController
    private var session: MediaSession? = null
    private lateinit var sessionActivity: PendingIntent
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val mediaItemFlow = MutableStateFlow(buildMediaItem(title = "folino", artist = ""))

    // Process-wide soundfont download bridge. Lazily resolved so the JNI library and the
    // @WireletProvided services are built only once the playback service is actually created.
    private val soundfontVM by lazy {
        com.keynumber.folino.soundfont.SoundfontController.viewModel(applicationContext)
    }

    // The score handle of the currently prepared playback, recorded by the audio view model via the
    // binder. Needed to re-prepare the engine when the soundfont is hot-swapped (the engine keeps its
    // handle private). Null when nothing is prepared.
    @Volatile private var preparedScoreHandle: Long? = null

    // A re-apply hook the audio view model registers so its own session-only preferences (master
    // volume, metronome on/off) — which the engine cannot report back after a re-prepare — are
    // re-pushed onto the engine once a soundfont reload rebuilds it.
    @Volatile private var onSoundfontReloaded: (() -> Unit)? = null

    // Set when a "downloaded" transition arrives while the engine is PLAYING. The swap is deferred to
    // the next non-playing transition so we never tear the engine down mid-stream.
    private var pendingSoundfontSwap = false

    private fun buildMediaItem(title: String, artist: String): MediaItem =
        MediaItem.Builder()
            .setMediaId("score")
            .setMediaMetadata(
                MediaMetadata.Builder().setTitle(title).setArtist(artist).build(),
            )
            .build()

    inner class LocalBinder : Binder() {
        val engine: AndroidPlaybackEngine get() = this@ReaderPlaybackService.engine

        fun updateMetadata(title: String, composer: String) {
            mediaItemFlow.value = buildMediaItem(
                title = title.ifBlank { "folino" },
                artist = composer,
            )
        }

        /**
         * Records the score handle the view model just prepared, so the service can re-prepare the
         * engine (picking up a newly downloaded soundfont) without exposing the engine's private handle.
         */
        fun notePreparedScore(scoreHandle: Long) {
            preparedScoreHandle = scoreHandle
        }

        /**
         * Registers a hook invoked after a soundfont hot-swap rebuilds the engine, so the view model can
         * re-push its session-only preferences (master volume, metronome on/off) that the engine resets
         * on re-prepare and cannot report back.
         */
        fun setOnSoundfontReloaded(block: (() -> Unit)?) {
            onSoundfontReloaded = block
        }
    }

    private val localBinder = LocalBinder()

    override fun onBind(intent: Intent?): IBinder? = when (intent?.action) {
        MediaSessionService.SERVICE_INTERFACE -> super.onBind(intent)
        else -> localBinder
    }

    override fun onCreate() {
        super.onCreate()
        engine = AndroidPlaybackEngine(
            context = applicationContext,
            soundfontResolver = FolinoSoundfontResolver(
                applicationContext,
                // Re-queried on every resolve, so a download that completes after prepare is picked up
                // by the next prepare/re-prepare. Empty string → fall back to the bundled GM SF2.
                highQualityPath = { soundfontVM.highQualityFilePath() },
            ),
            // folino's own click samples, the same pair iOS plays — see [BundledMetronomeClickProvider].
            metronomeClickProvider = BundledMetronomeClickProvider(applicationContext),
        )
        focusController = PlaybackFocusController(
            context = applicationContext,
            onPause = { engine.pause() },
            onResume = { engine.play() },
        )
        val player = EnginePlayer(engine, focusController, serviceScope, mediaItemFlow)
        // Re-launch Folino's launcher activity from the notification, resolved
        // by package (the Reader module does not depend on :app's MainActivity).
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        sessionActivity = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(sessionActivity)
            .build()
        ensureNotificationChannel()
        observeEngineForForegroundNotification()
        observeSoundfontDownload()
    }

    /**
     * Watches the soundfont download bridge and hot-swaps the engine onto the high-quality SF2 once it
     * reports "downloaded". The swap re-prepares the engine (which re-queries the resolver), so it is
     * only safe while not actively playing: if a download finishes mid-playback the swap is deferred to
     * the next non-playing transition.
     */
    private fun observeSoundfontDownload() {
        // React to a completed download.
        serviceScope.launch {
            soundfontVM.stateWire.collect { wire ->
                if (wire.statusRaw != "downloaded") return@collect
                if (engine.state.value == PlaybackState.PLAYING) {
                    pendingSoundfontSwap = true
                } else {
                    reloadSoundfont()
                }
            }
        }
        // Drain a deferred swap once playback stops/pauses.
        serviceScope.launch {
            engine.state.collect { state ->
                if (state != PlaybackState.PLAYING && pendingSoundfontSwap) {
                    pendingSoundfontSwap = false
                    reloadSoundfont()
                }
            }
        }
    }

    /**
     * Rebuilds the engine on the currently active soundfont, preserving the prepared score, playback
     * position, and the mixer state the engine cannot otherwise restore across a re-prepare.
     *
     * Engine-internal state that already survives `prepare` (master tuning / A4, playback rate) is left
     * to the engine. View-model-owned session preferences (master volume, metronome on/off) are re-pushed
     * via [onSoundfontReloaded].
     */
    private fun reloadSoundfont() {
        val handle = preparedScoreHandle ?: return
        // Nothing to rebuild unless the engine actually has a prepared score.
        if (engine.state.value == PlaybackState.STOPPED || engine.state.value == PlaybackState.EXPORTING) return
        serviceScope.launch {
            // Snapshot the bits the engine resets on re-prepare.
            val position = engine.currentTimeSeconds.value
            val channels: List<MixerChannel> = engine.mixerChannels.value
            try {
                // prepare() tears down the prior prepared state internally and re-queries the resolver,
                // so the rebuilt synth loads the now-downloaded high-quality SF2.
                engine.prepare(handle)
            } catch (ex: Exception) {
                android.util.Log.e("ReaderPlayback", "soundfont reload prepare failed: ${ex.message}", ex)
                return@launch
            }
            // Restore per-staff mixer state (volume / mute / solo / program).
            channels.forEach { ch ->
                ch.program?.let { engine.setStaffProgram(ch.staffIndex, it) }
                engine.setStaffVolume(ch.staffIndex, ch.volume)
                if (ch.isMuted) engine.setStaffMuted(ch.staffIndex, true)
                if (ch.isSoloed) engine.setStaffSoloed(ch.staffIndex, true)
            }
            // Re-push view-model-owned prefs (master volume, metronome) the engine can't report back.
            onSoundfontReloaded?.invoke()
            // Restore the playback position (re-prepare resets it to 0).
            engine.seek(toTimeSeconds = position)
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
    }

    private fun observeEngineForForegroundNotification() {
        serviceScope.launch {
            combine(engine.state, mediaItemFlow) { state, _ -> state }.collect { state ->
                when (state) {
                    PlaybackState.PLAYING -> postOrUpdateNotification(isPlaying = true)
                    PlaybackState.PAUSED -> postOrUpdateNotification(isPlaying = false)
                    PlaybackState.STOPPED, PlaybackState.PREPARED, PlaybackState.EXPORTING ->
                        stopForeground(STOP_FOREGROUND_REMOVE)
                }
            }
        }
    }

    private fun postOrUpdateNotification(isPlaying: Boolean) {
        val s = session ?: return
        val meta = mediaItemFlow.value.mediaMetadata
        val playPauseAction = NotificationCompat.Action(
            if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play_arrow,
            getString(if (isPlaying) R.string.reader_playback_pause else R.string.reader_playback_play),
            mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE),
        )
        val stopAction = NotificationCompat.Action(
            R.drawable.ic_stop,
            getString(R.string.reader_playback_stop),
            mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_STOP),
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_play_arrow)
            .setContentTitle(meta.title ?: "folino")
            .setContentText(meta.artist ?: "")
            .setContentIntent(sessionActivity)
            .addAction(playPauseAction)
            .addAction(stopAction)
            .setStyle(MediaStyle().setMediaSession(s.sessionCompatToken).setShowActionsInCompactView(0, 1))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * A [PendingIntent] that delivers a media-button [KeyEvent] to this `MediaSessionService`, which forwards
     * it to the session. Lets the notification's transport buttons drive the same play/pause/stop path the
     * lock screen and Bluetooth headset use.
     */
    private fun mediaButtonIntent(keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            setClass(this@ReaderPlaybackService, ReaderPlaybackService::class.java)
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        }
        return PendingIntent.getService(this, keyCode, intent, PendingIntent.FLAG_IMMUTABLE)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (session?.player?.playWhenReady != true) stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (::focusController.isInitialized) focusController.release()
        session?.run { player.release(); release() }
        session = null
        if (::engine.isInitialized) engine.teardown()
        serviceScope.cancel()
        super.onDestroy()
    }
}

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
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource
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
    private var session: MediaSession? = null
    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val mediaItemFlow = MutableStateFlow(buildMediaItem(title = "folino", artist = ""))

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
            soundfontResolver = FolinoSoundfontResolver(applicationContext),
            // MVP: no bundled click samples → GM drum-kit metronome.
            metronomeClickProvider = MetronomeClickProvider { MetronomeClickSource.DefaultGm },
        )
        val player = EnginePlayer(engine, serviceScope, mediaItemFlow)
        // Re-launch Folino's launcher activity from the notification, resolved
        // by package (the Reader module does not depend on :app's MainActivity).
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val sessionActivity = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(sessionActivity)
            .build()
        ensureNotificationChannel()
        observeEngineForForegroundNotification()
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
                    PlaybackState.PLAYING, PlaybackState.PAUSED -> postOrUpdateNotification()
                    PlaybackState.STOPPED, PlaybackState.PREPARED, PlaybackState.EXPORTING ->
                        stopForeground(STOP_FOREGROUND_REMOVE)
                }
            }
        }
    }

    private fun postOrUpdateNotification() {
        val s = session ?: return
        val meta = mediaItemFlow.value.mediaMetadata
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_play_arrow)
            .setContentTitle(meta.title ?: "folino")
            .setContentText(meta.artist ?: "")
            .setStyle(MediaStyle().setMediaSession(s.sessionCompatToken))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (session?.player?.playWhenReady != true) stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        session?.run { player.release(); release() }
        session = null
        if (::engine.isInitialized) engine.teardown()
        serviceScope.cancel()
        super.onDestroy()
    }
}

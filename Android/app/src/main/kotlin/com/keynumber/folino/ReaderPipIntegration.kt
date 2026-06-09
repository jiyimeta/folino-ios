package com.keynumber.folino

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import com.keynumber.folino.reader.ReaderPipController
import com.keynumber.folino.reader.pipAspectClamped
import kotlin.math.roundToInt

/** Broadcast contract for the in-window PiP controls. */
object ReaderPipActions {
    const val ACTION = "com.keynumber.folino.PIP_ACTION"
    const val EXTRA_CONTROL = "control"
    const val CONTROL_TOGGLE = "toggle"
    const val CONTROL_BACK = "back"        // -10s
    const val CONTROL_FORWARD = "forward"  // +10s
}

/**
 * Build PiP params: the window [aspect] (width/height, already content-derived; re-clamped here for
 * safety), the three RemoteActions (−10s, play/pause, +10s), and — on Android 12+ — auto-enter when
 * eligible. The play/pause glyph reflects [isPlaying].
 */
fun buildPipParams(
    activity: Activity,
    aspect: Double,
    isPlaying: Boolean,
    autoEnter: Boolean,
): PictureInPictureParams {
    val clamped = pipAspectClamped(aspect)
    val builder = PictureInPictureParams.Builder()
        .setAspectRatio(Rational((clamped * 100).roundToInt(), 100))
        .setActions(
            listOf(
                remoteAction(
                    activity, android.R.drawable.ic_media_rew, "Back 10s",
                    ReaderPipActions.CONTROL_BACK, requestCode = 1,
                ),
                remoteAction(
                    activity,
                    if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (isPlaying) "Pause" else "Play",
                    ReaderPipActions.CONTROL_TOGGLE, requestCode = 2,
                ),
                remoteAction(
                    activity, android.R.drawable.ic_media_ff, "Forward 10s",
                    ReaderPipActions.CONTROL_FORWARD, requestCode = 3,
                ),
            ),
        )
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        builder.setAutoEnterEnabled(autoEnter)
        builder.setSeamlessResizeEnabled(false)
    }
    return builder.build()
}

private fun remoteAction(
    activity: Activity,
    iconRes: Int,
    title: String,
    control: String,
    requestCode: Int,
): RemoteAction {
    val intent = Intent(ReaderPipActions.ACTION)
        .setPackage(activity.packageName)
        .putExtra(ReaderPipActions.EXTRA_CONTROL, control)
    val pi = PendingIntent.getBroadcast(
        activity, requestCode, intent,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    return RemoteAction(Icon.createWithResource(activity, iconRes), title, title, pi)
}

/** Routes in-window control taps to the Reader's transport hooks via [ReaderPipController]. */
class PipActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getStringExtra(ReaderPipActions.EXTRA_CONTROL)) {
            ReaderPipActions.CONTROL_TOGGLE -> ReaderPipController.onTogglePlayPause?.invoke()
            ReaderPipActions.CONTROL_BACK -> ReaderPipController.onSkip?.invoke(-10.0)
            ReaderPipActions.CONTROL_FORWARD -> ReaderPipController.onSkip?.invoke(10.0)
        }
    }
}

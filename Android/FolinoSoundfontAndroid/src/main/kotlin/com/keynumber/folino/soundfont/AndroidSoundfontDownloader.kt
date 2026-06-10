package com.keynumber.folino.soundfont

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.util.Log
import androidx.core.net.toUri
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Kotlin implementation of the generated `@WireletProvided` `SoundfontDownloader` interface using the system
 * `DownloadManager` (resilient for a ~206 MB transfer). Progress and terminal events are pushed back into the
 * Swift store via the [onProgress] / [onFinished] / [onFailed] callbacks (wired to the ViewModel's
 * `ingestProgress` / `ingestFinished` / `ingestFailed`).
 *
 * `DownloadManager` writes to its own staging location; on success the file is moved to [destinationPath] the
 * store handed us, then [onFinished] fires. A coroutine polls progress every 500 ms while the transfer runs.
 */
class AndroidSoundfontDownloader(
    context: Context,
    private val onProgress: (Double) -> Unit,
    private val onFinished: () -> Unit,
    private val onFailed: (String) -> Unit,
) : SoundfontDownloader {
    private val appContext = context.applicationContext
    private val dm = appContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val scope = CoroutineScope(Dispatchers.IO)
    private var pollJob: Job? = null
    private var currentId: Long = -1L

    override fun start(remoteURL: String, destinationPath: String, allowCellular: Boolean) {
        if (currentId != -1L) return // idempotent: a transfer is already running
        // DownloadManager runs in the system process and cannot write to our internal cacheDir/filesDir; it can
        // only write to our app-specific EXTERNAL files dir. Stage there, then copy into the internal final path.
        val external = appContext.getExternalFilesDir(null)
        if (external == null) {
            onFailed("external storage unavailable")
            return
        }
        val staging = File(external, STAGING_NAME)
        staging.delete()
        try {
            val request = DownloadManager.Request(remoteURL.toUri())
                .setDestinationInExternalFilesDir(appContext, null, STAGING_NAME)
                .setAllowedNetworkTypes(
                    if (allowCellular) {
                        DownloadManager.Request.NETWORK_WIFI or DownloadManager.Request.NETWORK_MOBILE
                    } else {
                        DownloadManager.Request.NETWORK_WIFI
                    },
                )
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_HIDDEN)
            currentId = dm.enqueue(request)
        } catch (e: Exception) {
            // Surface the failure as a retryable .failed state (and log, in case the callback's late-bound
            // ViewModel holder isn't wired yet during first construction).
            currentId = -1L
            Log.e("FolinoSoundfont", "DownloadManager.enqueue failed", e)
            onFailed("could not start download: ${e.message}")
            return
        }
        pollJob = scope.launch { poll(staging, File(destinationPath)) }
    }

    override fun cancel() {
        pollJob?.cancel()
        pollJob = null
        if (currentId != -1L) {
            dm.remove(currentId)
            currentId = -1L
        }
    }

    private suspend fun poll(staging: File, destination: File) {
        while (scope.isActive && currentId != -1L) {
            // Guard the whole tick: an unexpected throw (e.g. a missing DownloadManager column) must not kill the
            // scope permanently, which would silently brick every future start() until the process restarts.
            try {
                dm.query(DownloadManager.Query().setFilterById(currentId)).use { c: Cursor ->
                    if (!c.moveToFirst()) {
                        finish(failure = "download not found")
                        return
                    }
                    val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                    when (status) {
                        DownloadManager.STATUS_SUCCESSFUL -> {
                            destination.parentFile?.mkdirs()
                            staging.copyTo(destination, overwrite = true)
                            staging.delete()
                            finish(failure = null)
                            return
                        }
                        DownloadManager.STATUS_FAILED -> {
                            val reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                            finish(failure = "download failed (reason $reason)")
                            return
                        }
                        else -> {
                            val soFar = c.getLong(
                                c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                            )
                            val total = c.getLong(
                                c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                            )
                            if (total > 0) onProgress(soFar.toDouble() / total.toDouble())
                        }
                    }
                }
            } catch (e: Exception) {
                finish(failure = "download error: ${e.message}")
                return
            }
            delay(500)
        }
    }

    private fun finish(failure: String?) {
        currentId = -1L
        pollJob = null
        if (failure == null) onFinished() else onFailed(failure)
    }

    private companion object {
        const val STAGING_NAME = "MuseScore_General.sf2.part"
    }
}

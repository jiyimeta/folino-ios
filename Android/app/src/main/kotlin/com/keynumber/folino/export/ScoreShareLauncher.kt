package com.keynumber.folino.export

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

/** Shares produced export files via the Android share sheet. */
object ScoreShareLauncher {
    private const val AUTHORITY = "com.keynumber.folino.fileprovider"

    /** Cache subdir that backs the FileProvider `exports` path. Exported files are written here. */
    fun exportsDir(context: Context): File =
        File(context.cacheDir, "Exports").apply { mkdirs() }

    private fun mime(path: String): String = when (path.substringAfterLast('.').lowercase()) {
        "pdf" -> "application/pdf"
        "mid" -> "audio/midi"
        "m4a" -> "audio/mp4"
        "mscz" -> "application/octet-stream"
        else -> "application/octet-stream"
    }

    /** Launch the system share sheet for one or more produced files. No-op if none exist. */
    fun share(context: Context, paths: List<String>) {
        val files = paths.filter { it.isNotEmpty() }.map { File(it) }.filter { it.exists() }
        if (files.isEmpty()) return
        val uris = ArrayList(files.map { FileProvider.getUriForFile(context, AUTHORITY, it) })
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                putExtra(Intent.EXTRA_STREAM, uris[0])
                type = mime(files[0].path)
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                type = if (files.map { it.extension }.distinct().size == 1) mime(files[0].path) else "*/*"
            }
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(intent, null).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
    }
}

package com.keynumber.folino.share

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.util.UUID

/** A file copied out of a content:// share into our cache, ready for the importer. */
data class StagedShareFile(val path: String, val originalName: String)

// WARNING: must be kept in sync with Domain ShareImportPolicy.acceptedExtensions (JNI-opaque, can't be read from Kotlin).
private val ACCEPTED = setOf("mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid")

/// `true` when `name`'s extension is an accepted score format (iOS ShareImportPolicy parity).
/// Single Kotlin gate shared by the share-sheet/open-with transport and the Library "+" picker.
fun isAcceptedScoreFilename(name: String): Boolean =
    name.substringAfterLast('.', "").lowercase() in ACCEPTED

private fun isAccepted(name: String): Boolean = isAcceptedScoreFilename(name)

private fun displayName(context: Context, uri: Uri): String {
    if (uri.scheme == "file") return File(uri.path ?: "").name
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) {
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) c.getString(idx)?.let { return it }
        }
    }
    return uri.lastPathSegment ?: "shared"
}

/**
 * Copy each accepted URI into cacheDir/IncomingShare/<batch>/, returning the staged files and the count of
 * unsupported/failed ones. Acceptance is decided here (after we know the display name), mirroring the iOS UTI-broad /
 * extension-gated approach.
 */
fun stageSharedUris(context: Context, uris: List<Uri>): Pair<List<StagedShareFile>, Int> {
    val batchDir = File(context.cacheDir, "IncomingShare/${UUID.randomUUID()}").apply { mkdirs() }
    val staged = mutableListOf<StagedShareFile>()
    var unsupported = 0
    for (uri in uris) {
        val name = displayName(context, uri)
        if (!isAccepted(name)) {
            unsupported++
            continue
        }
        try {
            val dest = File(batchDir, name)
            val copied = context.contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { input.copyTo(it) }
                true
            } ?: false
            if (copied && dest.exists()) staged.add(StagedShareFile(dest.absolutePath, name)) else unsupported++
        } catch (e: Exception) {
            unsupported++
        }
    }
    return staged to unsupported
}

/** Best-effort cleanup of a staged batch dir after import. */
fun cleanupStaged(staged: List<StagedShareFile>) {
    staged.firstOrNull()?.let { File(it.path).parentFile?.deleteRecursively() }
}

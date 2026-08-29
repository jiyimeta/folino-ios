package com.keynumber.folino.editor

import java.io.File
import java.security.MessageDigest

/**
 * The Kotlin half of the editor's file seam.
 *
 * The digest format is load-bearing: it has to be the same lowercase hex SHA-256 the importer wrote, or a save makes
 * the library think it is looking at a new file. That is why this mirrors the importer's digest rather than picking
 * its own encoding.
 *
 * The row refresh is delegated rather than performed here: this module does not depend on `:FolinoLibraryAndroid`,
 * so `:app` supplies the [ScoreRowRefreshing] that owns the database — see that interface for why the update is
 * partial.
 */
class EditorRoomFiles(private val rows: ScoreRowRefreshing) : EditorHostFiles {

    fun refreshRow(id: String, localFileName: String, contentHash: String) =
        rows.refreshAfterSave(id, localFileName, contentHash)

    override fun sha256Hex(path: String): String {
        val file = File(path)
        if (!file.isFile) return ""
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    override fun fileSize(path: String): Long = File(path).let { if (it.isFile) it.length() else 0L }
}

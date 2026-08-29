package com.keynumber.folino.editor

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [EditorRoomFiles] — the editor's file seam: the digest and size a save derives, plus the two
 * library columns it writes back.
 *
 * The digest assertions pin the FORMAT, not just the value. It has to be the same lowercase hex SHA-256 the importer
 * wrote, or every save makes the library think it is looking at a new file.
 */
class EditorRoomFilesTest {

    /** Records what the seam forwarded, so the row half is assertable without Room. */
    private class RecordingRows : ScoreRowRefreshing {
        val calls = mutableListOf<Triple<String, String, String>>()
        override fun refreshAfterSave(id: String, localFileName: String, contentHash: String) {
            calls += Triple(id, localFileName, contentHash)
        }
    }

    @Test fun theDigestIsLowercaseHexSha256() {
        val file = File.createTempFile("editor-room-files", ".bin")
        file.writeBytes("abc".toByteArray())

        val hex = EditorRoomFiles(RecordingRows()).sha256Hex(file.absolutePath)

        // The published SHA-256 of "abc".
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex)
    }

    @Test fun aMissingFileHasNoDigestAndNoSizeRatherThanThrowing() {
        val files = EditorRoomFiles(RecordingRows())
        val absent = File.createTempFile("editor-room-files", ".bin").also { it.delete() }.absolutePath

        assertEquals("", files.sha256Hex(absent))
        assertEquals(0L, files.fileSize(absent))
    }

    @Test fun theSizeIsTheFilesByteCount() {
        val file = File.createTempFile("editor-room-files", ".bin")
        file.writeBytes(ByteArray(1234))

        assertEquals(1234L, EditorRoomFiles(RecordingRows()).fileSize(file.absolutePath))
    }

    @Test fun refreshRowForwardsExactlyTheThreeSaveDerivedValues() {
        val rows = RecordingRows()

        EditorRoomFiles(rows).refreshRow("score-id", "Etude.mscz", "deadbeef")

        assertEquals(1, rows.calls.size)
        assertEquals(Triple("score-id", "Etude.mscz", "deadbeef"), rows.calls.single())
    }

    @Test fun theSeamIsAFunInterfaceSoAMethodReferenceBindsIt() {
        val rows = RecordingRows()

        // How `:app` binds it: `EditorRoomFiles(RoomLibraryStore(context)::refreshRowAfterSave)`.
        EditorRoomFiles(rows::refreshAfterSave).refreshRow("id", "a.mscz", "f00d")

        assertTrue(rows.calls.isNotEmpty())
    }
}

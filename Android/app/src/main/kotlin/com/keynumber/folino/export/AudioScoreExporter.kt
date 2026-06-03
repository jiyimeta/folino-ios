package com.keynumber.folino.export

import android.content.Context
import android.os.ParcelFileDescriptor
import com.keynumber.folino.library.ScoreAudioFileExporter
import com.keynumber.folino.reader.FolinoSoundfontResolver
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import kotlinx.coroutines.runBlocking
import java.io.File

/**
 * Kotlin implementation of the generated `@WireletProvided`
 * [ScoreAudioFileExporter], injected into the Swift `LibraryAndroidStore` over
 * JNI.
 *
 * Reads the `.mscz` at `scoreFilePath`, loads a score handle, and renders the
 * full score to an M4A file at `outPath` via
 * [AndroidPlaybackEngine.exportAudioFile]. The Swift caller invokes this
 * synchronously across JNI, so the `suspend` export is bridged with
 * [runBlocking].
 *
 * The engine is built lazily through [engineFactory] (default reuses the same
 * [FolinoSoundfontResolver] the Reader uses, materializing the bundled GM
 * SoundFont). `exportAudioFile` requires the handle to have been [prepared]
 * [AndroidPlaybackEngine.prepare] first, so we prepare immediately before
 * exporting.
 */
class AudioScoreExporter(
    context: Context,
    private val engineFactory: () -> AndroidPlaybackEngine = {
        AndroidPlaybackEngine(
            context = context.applicationContext,
            soundfontResolver = FolinoSoundfontResolver(context.applicationContext),
        )
    },
) : ScoreAudioFileExporter {

    override fun exportAudio(scoreFilePath: String, outPath: String): Boolean {
        var handle: ScoreHandle? = null
        return try {
            val bytes = File(scoreFilePath).readBytes()
            val h = ScoreHandle.load(bytes) ?: return false
            handle = h

            val engine = engineFactory()
            val pfd = ParcelFileDescriptor.open(
                File(outPath),
                ParcelFileDescriptor.MODE_CREATE or
                    ParcelFileDescriptor.MODE_TRUNCATE or
                    ParcelFileDescriptor.MODE_WRITE_ONLY,
            )
            pfd.use {
                runBlocking {
                    // exportAudioFile throws NoScorePrepared unless the handle
                    // matches the most recent prepare() call.
                    engine.prepare(h.raw)
                    engine.exportAudioFile(
                        outputFd = it,
                        scoreHandle = h.raw,
                        format = AudioFileFormat.M4a(),
                        range = AudioExportRange.Full,
                    )
                }
            }
            true
        } catch (e: Exception) {
            false
        } finally {
            handle?.close()
        }
    }
}

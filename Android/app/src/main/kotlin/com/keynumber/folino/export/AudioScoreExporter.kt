package com.keynumber.folino.export

import android.content.Context
import android.os.ParcelFileDescriptor
import com.keynumber.folino.library.ScoreAudioFileExporter
import com.keynumber.folino.reader.BundledMetronomeClickProvider
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
// PARITY(android): exported audio ignores tuning — neither the A4 calibration nor the transpose reaches this path,
//   so an export sounds different from what the Reader played. Carry the engine's tuning state into the export
//   snapshot the way playback already does
class AudioScoreExporter(
    context: Context,
    private val engineFactory: () -> AndroidPlaybackEngine = {
        AndroidPlaybackEngine(
            context = context.applicationContext,
            // Prefer the downloaded high-quality SF2 so exported audio matches in-app playback; falls
            // back to the bundled GM SoundFont when absent or opted-out.
            soundfontResolver = FolinoSoundfontResolver(
                context.applicationContext,
                highQualityPath = {
                    com.keynumber.folino.soundfont.SoundfontController
                        .viewModel(context.applicationContext)
                        .highQualityFilePath()
                },
            ),
            // Same click the Reader plays, so an exported file's metronome matches what was heard.
            metronomeClickProvider = BundledMetronomeClickProvider(context.applicationContext),
        )
    },
) : ScoreAudioFileExporter {

    override fun exportAudio(scoreFilePath: String, outPath: String): Boolean {
        val bytes = File(scoreFilePath).readBytes()
        val handle = ScoreHandle.load(bytes) ?: return false
        return try {
            handle.use { h ->
                val outFile = File(outPath).apply { parentFile?.mkdirs() }
                ParcelFileDescriptor.open(
                    outFile,
                    ParcelFileDescriptor.MODE_CREATE or
                        ParcelFileDescriptor.MODE_TRUNCATE or
                        ParcelFileDescriptor.MODE_WRITE_ONLY,
                ).use { pfd ->
                    val engine = engineFactory()
                    try {
                        runBlocking {
                            // exportAudioFile throws NoScorePrepared unless the handle
                            // matches the most recent prepare() call.
                            engine.prepare(h.raw)
                            engine.exportAudioFile(
                                outputFd = pfd,
                                scoreHandle = h.raw,
                                format = AudioFileFormat.M4a(),
                                range = AudioExportRange.Full,
                            )
                        }
                    } finally {
                        engine.close()
                    }
                }
            }
            true
        } catch (e: Exception) {
            android.util.Log.w("AudioScoreExporter", "audio export failed for $scoreFilePath", e)
            false
        }
    }
}

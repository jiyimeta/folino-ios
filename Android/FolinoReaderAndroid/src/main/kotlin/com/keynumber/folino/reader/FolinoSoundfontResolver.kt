package com.keynumber.folino.reader

import android.content.Context
import android.net.Uri
import androidx.core.net.toUri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Resolves the SoundFont URI, preferring the downloaded high-quality `MuseScore_General.sf2` when present and
 * opted-in, else the bundled `GeneralUser-GS.sf2` materialized from assets to the cache dir.
 *
 * @param highQualityPath returns the absolute path of the downloaded high-quality SF2, or an empty string when it
 *   should not be used (absent or opted-out). Backed by the soundfont bridge's `highQualityFilePath()`.
 */
class FolinoSoundfontResolver(
    private val context: Context,
    private val highQualityPath: () -> String,
) : SoundfontResolver {

    private val bundledUri: Uri? by lazy {
        try {
            val out = File(context.cacheDir, "GeneralUser-GS.sf2")
            if (!out.exists()) {
                context.assets.open("GeneralUser-GS.sf2").use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
            }
            out.absoluteFile.toUri()
        } catch (e: Exception) {
            android.util.Log.w("FolinoSoundfont", "GeneralUser-GS.sf2 missing — audio silent", e)
            null
        }
    }

    private fun activeUri(): Uri? {
        val hq = highQualityPath()
        if (hq.isNotEmpty()) {
            val f = File(hq)
            if (f.exists()) return f.absoluteFile.toUri()
        }
        return bundledUri
    }

    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = activeUri()
    override val defaultGmSoundfontUri: Uri? get() = activeUri()
}

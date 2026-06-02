package com.keynumber.folino.reader

import android.content.Context
import android.net.Uri
import androidx.core.net.toUri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Resolves the SoundFont URI from the bundled General MIDI SoundFont
 * (`GeneralUser-GS.sf2`), materialized from assets to the cache dir on
 * first use. Both melodic and drum lookups return the same GM SF2 for
 * the MVP. The MuseScoreGeneral high-quality download is out of scope.
 */
class FolinoSoundfontResolver(private val context: Context) : SoundfontResolver {

    private val cachedUri: Uri? by lazy {
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

    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = cachedUri
    override val defaultGmSoundfontUri: Uri? get() = cachedUri
}

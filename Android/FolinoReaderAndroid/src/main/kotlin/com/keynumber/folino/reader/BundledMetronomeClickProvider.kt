package com.keynumber.folino.reader

import android.content.Context
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource

/**
 * Drives the metronome from folino's bundled click samples (`assets/Clicks/click_strong.wav` +
 * `click_weak.wav`) instead of the GM wood-block drum kit — the same two WAVs the iOS app ships, so the
 * click sounds identical on both platforms. The engine converts the pair to an SF2 once (through the
 * shared Swift `ClickSoundFontBuilder`) and caches the result by content.
 *
 * Falls back to [MetronomeClickSource.DefaultGm] when either sample is missing, so a stripped asset set
 * degrades to the legacy click rather than silencing the metronome. Mirrors iOS's
 * `BundledMetronomeClickProvider`.
 */
class BundledMetronomeClickProvider(context: Context) : MetronomeClickProvider {
    private val assets = context.applicationContext.assets

    override fun metronomeClickSource(): MetronomeClickSource {
        val strong = readAsset("Clicks/click_strong.wav")
        val weak = readAsset("Clicks/click_weak.wav")
        if (strong == null || weak == null) return MetronomeClickSource.DefaultGm
        return MetronomeClickSource.ClickSamples(strongWav = strong, weakWav = weak)
    }

    private fun readAsset(path: String): ByteArray? = try {
        assets.open(path).use { it.readBytes() }
    } catch (_: Exception) {
        null
    }
}

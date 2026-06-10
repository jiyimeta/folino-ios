package com.keynumber.folino.soundfont

import android.content.Context
import com.keynumber.folino.soundfont.generated.MuseScoreGeneralAndroidStoreViewModel

/**
 * Process-wide owner of the soundfont download bridge. Builds the `@WireletProvided` Kotlin services, wires their
 * callbacks to the generated ViewModel's `@WireletExpose` ingest methods, and exposes the ViewModel for Compose
 * and the audio resolver / playback service.
 *
 * Single instance per process (the high-quality SF2 is global). Construct once and reuse.
 */
object SoundfontController {
    @Volatile private var vm: MuseScoreGeneralAndroidStoreViewModel? = null

    fun viewModel(context: Context): MuseScoreGeneralAndroidStoreViewModel =
        vm ?: synchronized(this) { vm ?: build(context).also { vm = it } }

    private fun build(context: Context): MuseScoreGeneralAndroidStoreViewModel {
        val app = context.applicationContext
        // Late-bound holder so the services can call into the ViewModel that is constructed with them.
        val holder = arrayOfNulls<MuseScoreGeneralAndroidStoreViewModel>(1)
        val downloader = AndroidSoundfontDownloader(
            context = app,
            onProgress = { holder[0]?.ingestProgress(it) },
            onFinished = { holder[0]?.ingestFinished() },
            onFailed = { holder[0]?.ingestFailed(it) },
        )
        val reachability = AndroidNetworkReachability(
            context = app,
            onReachabilityChanged = { holder[0]?.onReachabilityChanged(it) },
        )
        val prefs = SoundfontPrefsStoreImpl(app)
        val created = MuseScoreGeneralAndroidStoreViewModel.create(downloader, reachability, prefs)
        holder[0] = created
        return created
    }
}

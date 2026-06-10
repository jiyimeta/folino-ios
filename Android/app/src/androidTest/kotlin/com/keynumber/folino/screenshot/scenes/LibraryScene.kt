package com.keynumber.folino.screenshot.scenes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.keynumber.folino.library.RoomLibraryStore
import com.keynumber.folino.library.ScoreAudioFileExporter
import com.keynumber.folino.library.ScorePdfRenderer
import com.keynumber.folino.library.ScoreRecordWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.MockScores
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.library.LibraryScreen
import com.keynumber.folino.ui.theme.FolinoTheme

// Library walking skeleton: seed Room with three deterministic mock rows, stage their backing files,
// then render the REAL production `LibraryScreen` inside the marketing frame. Proves the full
// pipeline (seed → real composable → frame → fixed-size capture → collect → fastlane tree).
@Composable
fun LibraryScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("Library", tag)
    val context = LocalContext.current.applicationContext
    val viewModel = remember {
        MockScores.stageScoreFiles(context)
        val store = RoomLibraryStore(context)
        MockScores.all.forEach { mock ->
            store.upsert(
                ScoreRecordWire(
                    id = mock.id,
                    title = mock.title,
                    subtitle = "",
                    composer = mock.composer,
                    arranger = null,
                    lyricist = null,
                    copyright = null,
                    localFileName = "${mock.id}.mscz",
                    contentHash = "",
                    deletedAt = 0.0, // 0 == live (LibraryAndroidStore filters deletedAt <= 0)
                    lastOpenedAt = 0.0,
                    isFavorite = false,
                ),
            )
        }
        // No-op export adapters: a static Library list never invokes PDF/audio export, and the real
        // AudioScoreExporter spins up a native playback engine (soundfont + audio output) per VM,
        // which is wasteful and crash-prone inside the instrumented capture. The stubs satisfy the
        // interfaces without touching native code.
        val vm = LibraryAndroidStoreViewModel.create(
            store = store,
            pdfRenderer = NoopPdfRenderer,
            audioExporter = NoopAudioExporter,
        )
        // The Swift store hydrates `scores` in its init via `reload()`, but that runs *before* the
        // JNI back-channel to this Kotlin `store` is live, so the init-time `loadAll()` comes back
        // empty and the VM's `scores` flow starts at []. The app never hits this because it only ever
        // mutates the store *after* construction (import/restore/delete each end in `reload()`). We
        // reproduce that post-construction reload deterministically with a no-op bulk restore:
        // `restoreMany([])` skips its (empty) id loop and falls through to `reload(using: loadAll())`,
        // which now sees the three seeded rows over the live bridge and repopulates `scores`.
        android.util.Log.e("ScreenshotLib", "preRestore vmScores=${vm.scores.value.size} loadAll=${store.loadAll().size}")
        vm.restoreMany(emptyList())
        android.util.Log.e("ScreenshotLib", "postRestoreImmediate vmScores=${vm.scores.value.size}")
        vm
    }
    androidx.compose.runtime.LaunchedEffect(viewModel) {
        kotlinx.coroutines.delay(500)
        android.util.Log.e("ScreenshotLib", "afterDelay vmScores=${viewModel.scores.value.size}")
    }
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            LibraryScreen(
                viewModel = viewModel,
                onOpenScore = {},
                onOpenDrawer = {},
                onEditInfoForScore = {},
            )
        }
    }
}

private object NoopPdfRenderer : ScorePdfRenderer {
    override fun renderPdf(scoreFilePath: String, outPath: String): Boolean = false
}

private object NoopAudioExporter : ScoreAudioFileExporter {
    override fun exportAudio(scoreFilePath: String, outPath: String): Boolean = false
}

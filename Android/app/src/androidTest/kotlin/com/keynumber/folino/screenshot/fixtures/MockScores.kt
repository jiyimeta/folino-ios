package com.keynumber.folino.screenshot.fixtures

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

// Three deterministic mock library rows derived from the bundled Now_is_the_time.mscz.
// Fixed UUIDs keep capture output stable across runs. The mscz asset is copied into
// filesDir/Scores/<id>.mscz for each; metadata is seeded directly into folino-library.db.
object MockScores {
    data class Mock(val id: String, val title: String, val composer: String)

    val all = listOf(
        Mock("00000000-0000-0000-0000-0000000000a1", "Now is the time", "Trad."),
        Mock("00000000-0000-0000-0000-0000000000a2", "アタタメマスカ", ""), // composer cleared (blank)
        Mock("00000000-0000-0000-0000-0000000000a3", "Looks_Good_To_Me", "K. Ito"),
    )

    // Copies the test asset into filesDir/Scores/<id>.mscz for every mock row.
    //
    // The .mscz lives in the *test* APK's assets, but the file must land in the *app under test's*
    // filesDir. `context` (from LocalContext.current) is the app context — its assets do NOT contain
    // the test asset — so we read bytes from the instrumentation (test) context's AssetManager.
    fun stageScoreFiles(context: Context) {
        val scoresDir = File(context.filesDir, "Scores").apply { mkdirs() }
        val testAssets = InstrumentationRegistry.getInstrumentation().context.assets
        testAssets.open("Now_is_the_time.mscz").use { input ->
            val bytes = input.readBytes()
            all.forEach { mock ->
                File(scoresDir, "${mock.id}.mscz").writeBytes(bytes)
            }
        }
    }
}

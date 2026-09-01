package com.keynumber.folino

import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.library.RoomLibraryStore
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Deterministic smoke for the import path: import a bundled fixture .mscz through the
 * real generated LibraryAndroidStoreViewModel and assert it persists into the shared
 * Room DB. Exercises nativeImportScore + the Room write (and the native nativeNew the
 * VM constructor calls) — the path the silent import failure lived on. Asserts via
 * RoomLibraryStore.loadAll() (synchronous, shared singleton DB) to avoid StateFlow timing.
 */
@RunWith(AndroidJUnit4::class)
class ImportSmokeTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val store = RoomLibraryStore(context)

    @Before
    fun clearScores() {
        // This wipes the library it runs against — `deleteRecord` is a DELETE, not a soft delete —
        // and `connectedAndroidTest` runs on whatever `adb devices` shows. On 2026-08-31 that was a
        // real Pixel, and it took the scores, per-score preferences and annotations with it (the
        // .mscz files in filesDir survived, but nothing referenced them any more). The clearing
        // itself is not optional: import de-duplicates, so a second run against a library that
        // already holds the fixture would add nothing and fail the delta assertion. So gate the
        // whole test on being an emulator rather than trying to clear more surgically.
        assumeTrue("ImportSmokeTest clears the library; it only runs on an emulator", isEmulator())
        store.loadAll().forEach { store.deleteRecord(it.id) }
    }

    // Emulator images report a `ranchu`/`goldfish` hardware and an `sdk_`-prefixed product; the
    // fingerprint check catches images that predate those. Any one of them is enough — a real
    // device matches none.
    private fun isEmulator(): Boolean =
        Build.HARDWARE == "ranchu" ||
            Build.HARDWARE.startsWith("goldfish") ||
            Build.PRODUCT.startsWith("sdk") ||
            Build.PRODUCT.contains("emulator") ||
            Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator")

    @Test
    fun importsFixtureScore() {
        val tmp = File.createTempFile("smoke", ".mscz", context.cacheDir)
        // The fixture is bundled in the instrumentation APK, not the app-under-test APK, so
        // it must be read from the instrumentation context — getApplicationContext() returns
        // the target app context, whose assets do not contain smoke.mscz.
        val testAssets = InstrumentationRegistry.getInstrumentation().context.assets
        testAssets.open("smoke.mscz").use { input ->
            tmp.outputStream().use { input.copyTo(it) }
        }

        val before = store.loadAll().count { it.deletedAt <= 0.0 }

        // Real generated VM via the same factory the app uses (LibraryVMFactory, same package).
        val vm: LibraryAndroidStoreViewModel =
            LibraryVMFactory(context.applicationContext)
                .create(LibraryAndroidStoreViewModel::class.java)
        vm.importScore(tmp.absolutePath)

        val after = store.loadAll().count { it.deletedAt <= 0.0 }
        assertEquals("import should add exactly one active score", before + 1, after)
    }
}

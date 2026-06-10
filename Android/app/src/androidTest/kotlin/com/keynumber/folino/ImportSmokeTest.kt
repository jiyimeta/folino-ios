package com.keynumber.folino

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.keynumber.folino.library.RoomLibraryStore
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import org.junit.Assert.assertEquals
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
        // Known starting state on the emulator: drop existing rows so the delta is unambiguous.
        store.loadAll().forEach { store.deleteRecord(it.id) }
    }

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

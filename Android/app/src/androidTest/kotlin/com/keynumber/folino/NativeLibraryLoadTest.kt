package com.keynumber.folino

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Deterministic guard: every Folino JNI native library must load. Each entry class's
 * static initializer runs its System.loadLibrary; a missing/un-staged .so throws
 * ExceptionInInitializerError / UnsatisfiedLinkError here — catching the exact failure
 * (e.g. libFolinoSoundfontJNI.so absent) that otherwise only surfaces on score-open.
 */
@RunWith(AndroidJUnit4::class)
class NativeLibraryLoadTest {
    private val entryClasses = listOf(
        "com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel",
        "com.keynumber.folino.settings.swiftjava.FolinoSettingsJNI",
        "com.keynumber.folino.reader.swiftjava.FolinoReaderJNI",
        "com.keynumber.folino.soundfont.generated.MuseScoreGeneralAndroidStoreViewModel",
    )

    @Test
    fun allFolinoNativeLibrariesLoad() {
        val cl = javaClass.classLoader!!
        for (fqcn in entryClasses) {
            // initialize = true forces the static initializer (System.loadLibrary) to run.
            Class.forName(fqcn, true, cl)
        }
    }
}

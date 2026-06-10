package com.keynumber.folino

import android.app.Application
import com.keynumber.folino.diagnostics.CrashReporting

/**
 * Eager-loads every Folino JNI native library at process start. Without this, only
 * libFolinoLibraryJNI/libFolinoSettingsJNI load at launch (their classes are used on
 * the start screen); libFolinoReaderJNI/libFolinoSoundfontJNI load lazily on score-open.
 * A missing/broken .so would then crash deep in a flow instead of at launch. Forcing all
 * four to load here makes such a packaging failure fail FAST (visible to any launch check).
 *
 * Each entry class's static initializer runs the corresponding System.loadLibrary; we
 * trigger them via Class.forName(initialize = true).
 */
class FolinoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        loadNativeEntryClasses()
    }

    private fun loadNativeEntryClasses() {
        val cl = javaClass.classLoader!!
        for (fqcn in NATIVE_ENTRY_CLASSES) {
            try {
                Class.forName(fqcn, /* initialize = */ true, cl)
            } catch (t: Throwable) {
                // A failure here means a native lib is missing/broken in this build.
                // Record it as a non-fatal for diagnostics, then fail fast at launch
                // rather than later on score-open.
                CrashReporting.recordNonFatal(t)
                throw t
            }
        }
    }

    private companion object {
        val NATIVE_ENTRY_CLASSES = listOf(
            "com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel",
            "com.keynumber.folino.settings.swiftjava.FolinoSettingsJNI",
            "com.keynumber.folino.reader.swiftjava.FolinoReaderJNI",
            "com.keynumber.folino.soundfont.generated.MuseScoreGeneralAndroidStoreViewModel",
        )
    }
}

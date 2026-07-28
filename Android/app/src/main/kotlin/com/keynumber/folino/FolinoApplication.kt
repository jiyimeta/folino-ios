package com.keynumber.folino

import android.app.Application
import com.keynumber.folino.diagnostics.CrashReporting
import com.keynumber.folino.reader.ReaderDiagnostics

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
        // The Reader module can't reach `CrashReporting` itself (`:app` depends on it, not the other way round), so
        // the composition root hands it the sink. Installed BEFORE the native load below, so a load failure's own
        // report is the first thing this seam carries.
        ReaderDiagnostics.install(CrashReporting::recordNonFatal)
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

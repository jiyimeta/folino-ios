package com.keynumber.folino.diagnostics

import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * Thin wrapper over Firebase Crashlytics so the rest of the app does not import the SDK directly.
 *
 * Crashlytics auto-initializes via its ContentProvider; this only toggles data collection.
 * DataStore (`SettingsPrefs.crashReporting`) is the source of truth — we re-apply it on every
 * launch, mirroring iOS which re-applies the UserDefaults flag at bootstrap.
 */
object CrashReporting {
    fun setCollectionEnabled(enabled: Boolean) {
        FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = enabled
    }

    /**
     * Record a non-fatal exception. The app keeps running; the report is uploaded on the next
     * launch (subject to the collection-enabled flag). Used by the debug menu to exercise the
     * Crashlytics pipeline without crashing.
     */
    fun recordNonFatal(throwable: Throwable) {
        FirebaseCrashlytics.getInstance().recordException(throwable)
    }
}

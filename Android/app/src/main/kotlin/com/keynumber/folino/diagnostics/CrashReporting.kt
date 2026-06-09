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
}

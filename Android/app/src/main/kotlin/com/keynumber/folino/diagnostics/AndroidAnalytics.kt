package com.keynumber.folino.diagnostics

import android.content.Context
import android.os.Bundle
import com.google.firebase.analytics.FirebaseAnalytics
import com.keynumber.folino.library.AnalyticsEventWire
import com.keynumber.folino.library.AnalyticsPropertyWire
import com.keynumber.folino.library.generated.AnalyticsBridgeViewModel

/**
 * Thin wrapper over Firebase Analytics so the rest of the app does not import the SDK directly. Mirrors
 * [CrashReporting]: DataStore (`SettingsPrefs.analytics`) is the source of truth and we re-apply it on every launch,
 * matching iOS which re-applies the UserDefaults flag at bootstrap.
 *
 * Event names + parameters are NEVER literalled here. They come from the shared Domain/UtilityCore catalog via the
 * Swift [AnalyticsBridgeViewModel] builders (`bridge.settingsOpened()` etc.), so iOS and Android stay byte-identical.
 * This object only owns the Firebase SDK call and the local opt-out gate.
 *
 * The `enabled` gate is defense-in-depth, mirroring iOS `AnalyticsEnabledFlag`: events are dropped before reaching
 * Firebase when the user has opted out, in addition to the SDK-level `setAnalyticsCollectionEnabled` toggle.
 */
object AndroidAnalytics {
    @Volatile private var enabled: Boolean = true
    @Volatile private var firebaseAnalytics: FirebaseAnalytics? = null
    @Volatile private var bridgeInstance: AnalyticsBridgeViewModel? = null

    /**
     * The Swift event-builder bridge. Stateless and process-lifetime: created once, never released (mirrors
     * [com.keynumber.folino.soundfont.SoundfontController] holding its generated ViewModel for the whole process).
     * First access triggers `System.loadLibrary("FolinoLibraryJNI")` via the generated companion `init` — a no-op
     * if the .so is already loaded (it is, eagerly, at app start via FolinoApplication's NATIVE_ENTRY_CLASSES).
     */
    val bridge: AnalyticsBridgeViewModel
        get() = bridgeInstance ?: synchronized(this) {
            bridgeInstance ?: AnalyticsBridgeViewModel.create().also { bridgeInstance = it }
        }

    /**
     * Bind the Firebase Analytics instance to the app context. Call once at startup (MainActivity) before
     * [setCollectionEnabled], since `FirebaseAnalytics.getInstance` needs a Context (unlike Crashlytics, which
     * resolves a no-arg singleton).
     */
    fun initialize(context: Context) {
        if (firebaseAnalytics == null) {
            synchronized(this) {
                if (firebaseAnalytics == null) {
                    firebaseAnalytics = FirebaseAnalytics.getInstance(context.applicationContext)
                }
            }
        }
    }

    /** Toggle collection: flips the local gate AND the Firebase SDK flag. The SDK call no-ops until [initialize]. */
    fun setCollectionEnabled(value: Boolean) {
        enabled = value
        firebaseAnalytics?.setAnalyticsCollectionEnabled(value)
    }

    /**
     * Set (or clear, when [value] is null) a user property. No-op when the local gate is disabled or before
     * [initialize]. Property names come from the shared catalog via the bridge's `libraryUserProperties()` /
     * `launchUserProperties(...)` builders ([AnalyticsPropertyWire]), never literalled here. Mirrors iOS
     * `Analytics.setUserProperty(_:for:)`.
     */
    fun setUserProperty(name: String, value: String?) {
        if (!enabled) return
        firebaseAnalytics?.setUserProperty(name, value)
    }

    /** Convenience: apply a batch of [AnalyticsPropertyWire] from a bridge builder. */
    fun applyUserProperties(properties: List<AnalyticsPropertyWire>) {
        for (property in properties) setUserProperty(property.name, property.value)
    }

    /**
     * Log an event produced by an [AnalyticsBridgeViewModel] builder. No-op when the local gate is disabled or
     * before [initialize]. Each parameter's `kind` selects the `Bundle` putter: 0 string, 1 long, 2 double,
     * 3 bool (passed as long 1/0 — a documented parity detail; iOS passes a native Bool).
     */
    fun log(event: AnalyticsEventWire) {
        if (!enabled) return
        val analytics = firebaseAnalytics ?: return
        analytics.logEvent(event.name, bundle(event))
    }

    /** Build a Firebase `Bundle` from a wire event's parameters. Package-visible for unit testing the kind mapping. */
    internal fun bundle(event: AnalyticsEventWire): Bundle = Bundle().apply {
        for (param in event.params) {
            when (param.kind) {
                0 -> putString(param.key, param.stringValue)
                1 -> putLong(param.key, param.longValue.toLong())
                2 -> putDouble(param.key, param.doubleValue)
                3 -> putLong(param.key, if (param.boolValue) 1L else 0L)
            }
        }
    }
}

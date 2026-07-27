package com.keynumber.folino.ui.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.keynumber.folino.reader.ink.AnnotationTool
import com.keynumber.folino.reader.ink.AnnotationToolState
import com.keynumber.folino.reader.ink.AnnotationWidths
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

val Context.dataStore by preferencesDataStore(name = "folino_settings")

object SettingsKeys {
    val metronomeEnabled = booleanPreferencesKey("reader.metronome.enabled")

    /**
     * Whether playback counts a measure of clicks in before the score starts. Same key name as iOS
     * `ReaderGlobalSettingsKey.precountEnabled`; default off, as on iOS.
     */
    val precountEnabled = booleanPreferencesKey("readerPrecountEnabled")
    /**
     * Whether the Reader auto-enters Picture-in-Picture when the app is backgrounded during playback.
     * Opt-*out*: absent means enabled, mirroring iOS `ReaderGlobalSettingsKey.pictureInPictureEnabled`.
     */
    val pipEnabled = booleanPreferencesKey("reader.pictureInPicture.enabled")

    /**
     * Set once [SettingsPrefs.applyPictureInPictureOptOutMigration] has force-enabled PiP for an install
     * that predates the opt-in → opt-out flip. Mirrors iOS `PictureInPictureOptOutMigration.appliedKey`.
     */
    val pipForcedOnApplied = booleanPreferencesKey("reader.pictureInPicture.forcedOn.v1")
    val collapseRests = booleanPreferencesKey("reader.collapseMultiMeasureRests")
    val keepAwake = booleanPreferencesKey("reader.keepScreenAwake.enabled")
    val layoutMode = stringPreferencesKey("reader.layoutMode") // "vertical" | "horizontal" | "page"
    val staffSize = doublePreferencesKey("reader.staffSize")
    val honorBreaks = booleanPreferencesKey("reader.honorLayoutBreaks")
    val showInvisible = booleanPreferencesKey("reader.showInvisibleElements")
    /**
     * Each element encodes a hidden staff address as `"<partIndex>:<staffIndexInPart>"`,
     * e.g. `"0:1"` means part 0, second staff. Callers build and parse the strings.
     */
    val hiddenStaves = stringSetPreferencesKey("reader.hiddenStaves")
    /**
     * Each element encodes a clef override as `"<partIndex>:<staffIndexInPart>=<rawType>"`,
     * e.g. `"0:1=F8va"` means part 0, second staff, overridden to bass-8va clef.
     * Callers build and parse the strings; rawType matches the sheet-music engine's clef type names.
     */
    val clefOverrides = stringSetPreferencesKey("reader.clefOverrides")
    /** Set once the user has interacted with the page-mode tap-zone overlay; suppresses the onboarding hint. */
    val pageTapHintDismissed = booleanPreferencesKey("reader.pageTapHintDismissed")
    /** Whether the Reader shows the full-width seek bar (true) or the floating play FAB (false).
     * Default true mirrors iOS `ReaderGlobalSettingsKey.showSeekBarEnabled`. UI-only; not part of
     * the JNI layout blob. */
    val showSeekBar = booleanPreferencesKey("reader.showSeekBar.enabled")
    /** Whether continuous playback auto-scrolls / auto-page-turns the score, and pausing recenters the
     * viewport on the playhead. Default true mirrors iOS `ReaderGlobalSettingsKey.autoFollowEnabled`.
     * When off the reader keeps full manual control of the viewport during playback. */
    val autoFollowEnabled = booleanPreferencesKey("reader.autoFollow.enabled")
    /** Whether the page-mode tap zones (edge buttons that turn the page) render. Default true mirrors
     * iOS `ReaderGlobalSettingsKey.pageTurnButtonsVisible`. When off, swiping to turn pages still
     * works — only the tap zones themselves are hidden. Has no effect outside page mode. */
    val pageTurnButtonsVisible = booleanPreferencesKey("reader.pageTurnButtonsVisible.enabled")
    /**
     * Global A4 reference pitch in Hz. Shared key with the iOS side so both platforms default to
     * the same persisted value when reading a cross-platform DataStore export.
     */
    val a4ReferenceHz = doublePreferencesKey("reader.a4ReferenceHz")
    /**
     * Global sticky repeat mode: "off" | "loopAll" | "abLoop". Shared key intent with iOS
     * `ReaderGlobalSettingsKey.repeatMode`. Default "off".
     */
    val repeatMode = stringPreferencesKey("reader.repeatMode")
    /**
     * Global sticky playlist-continuation mode: "off" | "playThrough" | "loopPlaylist".
     * Shared key intent with iOS `ReaderGlobalSettingsKey.playlistContinuationMode`.
     * Default "playThrough". Persist-only on Android for now — the playlist continuous-playback
     * feature that consumes this value is not yet built here, so selecting only saves the choice.
     */
    val playlistContinuationMode = stringPreferencesKey("playlistContinuationMode")
    /**
     * Active library sort as a `Domain.ScoreItemSort` rawValue ("dateAddedDesc" | "titleAsc" |
     * "composerAsc" | "lastOpenedDesc"). Same key name as iOS `LibrarySettingsKey.sortOrder`. Absent
     * ⇒ the Swift store's own default; Kotlin never interprets the value, it only stores it.
     */
    val librarySortOrder = stringPreferencesKey("librarySortOrder")

    /**
     * Whether Crashlytics crash-data collection is enabled. Opt-out semantics:
     * absent (first launch) is treated as `true`, mirroring iOS
     * `privacyCrashReportingEnabled`. The toggle is an opt-*out*.
     */
    val crashReportingEnabled = booleanPreferencesKey("privacy.crashReporting.enabled")

    /**
     * Whether Firebase Analytics usage collection is enabled. Opt-out semantics:
     * absent (first launch) is treated as `true`, mirroring iOS
     * `privacyAnalyticsEnabled`. The toggle is an opt-*out*.
     */
    val analyticsEnabled = booleanPreferencesKey("privacy.analytics.enabled")

    /**
     * Per-pen stroke widths for the annotation toolbar (index into
     * [com.keynumber.folino.reader.ink.AnnotationToolbarDefaults.DEFAULT_COLORS]). Each palette slot
     * remembers its own width independently, mirroring [AnnotationToolState.penWidths].
     */
    val annotationPenWidths = listOf(0, 1, 2, 3).map { floatPreferencesKey("annotation.penWidth$it") }

    /** Stroke width (document mm) for the partial eraser, shared across all uses. */
    val annotationEraserWidth = floatPreferencesKey("annotation.eraserWidth")

    /**
     * Encoded selected annotation tool: `"pen:<colorIndex>"` or `"eraser"`. See
     * [decodeAnnotationTool] / [encodeAnnotationTool] for the total encode/decode pair.
     */
    val annotationSelectedTool = stringPreferencesKey("annotation.selectedTool")
}

class SettingsPrefs(private val context: Context) {
    val metronome: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.metronomeEnabled] ?: false }
    val precount: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.precountEnabled] ?: false }
    val pip: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pipEnabled] ?: true }
    val collapseRests: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.collapseRests] ?: false }
    val keepAwake: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.keepAwake] ?: true }
    val layoutMode: Flow<String> = context.dataStore.data.map { it[SettingsKeys.layoutMode] ?: "page" }
    val staffSize: Flow<Double> = context.dataStore.data.map { it[SettingsKeys.staffSize] ?: 28.0 }
    val honorBreaks: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.honorBreaks] ?: true }
    val showInvisible: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.showInvisible] ?: false }
    val hiddenStaves: Flow<Set<String>> = context.dataStore.data.map { it[SettingsKeys.hiddenStaves] ?: emptySet() }
    val clefOverrides: Flow<Set<String>> = context.dataStore.data.map { it[SettingsKeys.clefOverrides] ?: emptySet() }
    val pageTapHintDismissed: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pageTapHintDismissed] ?: false }
    val showSeekBar: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.showSeekBar] ?: true }
    val autoFollow: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.autoFollowEnabled] ?: true }
    val pageTurnButtonsVisible: Flow<Boolean> =
        context.dataStore.data.map { it[SettingsKeys.pageTurnButtonsVisible] ?: true }
    val a4ReferenceHz: Flow<Double> = context.dataStore.data.map { it[SettingsKeys.a4ReferenceHz] ?: 440.0 }
    val repeatMode: Flow<String> = context.dataStore.data.map { it[SettingsKeys.repeatMode] ?: "off" }
    val playlistContinuationMode: Flow<String> =
        context.dataStore.data.map { it[SettingsKeys.playlistContinuationMode] ?: "playThrough" }
    /** Null until the user picks a sort — the caller then leaves the Swift store on its own default. */
    val librarySortOrder: Flow<String?> = context.dataStore.data.map { it[SettingsKeys.librarySortOrder] }
    val crashReporting: Flow<Boolean> =
        context.dataStore.data.map { it[SettingsKeys.crashReportingEnabled] ?: true }
    val analytics: Flow<Boolean> =
        context.dataStore.data.map { it[SettingsKeys.analyticsEnabled] ?: true }

    /**
     * Combined annotation pen-setup snapshot (four pen widths, the eraser width, the selected tool).
     * Missing/garbage-encoded keys fall back to the [AnnotationToolState] no-arg defaults field by
     * field, so a fresh install or a partially-written prefs blob never fails to produce a value.
     */
    val annotationToolState: Flow<AnnotationToolState> = context.dataStore.data.map { p ->
        AnnotationToolState(
            selected = decodeAnnotationTool(p[SettingsKeys.annotationSelectedTool]),
            penWidths = SettingsKeys.annotationPenWidths.mapIndexed { i, key ->
                p[key] ?: AnnotationWidths.PEN_DEFAULTS[i]
            },
            eraserWidth = p[SettingsKeys.annotationEraserWidth] ?: AnnotationWidths.ERASER_PRESETS[1],
        )
    }

    suspend fun setMetronome(v: Boolean) = context.dataStore.edit { it[SettingsKeys.metronomeEnabled] = v }
    suspend fun setPrecount(v: Boolean) = context.dataStore.edit { it[SettingsKeys.precountEnabled] = v }
    suspend fun setPip(v: Boolean) = context.dataStore.edit { it[SettingsKeys.pipEnabled] = v }
    suspend fun setCollapseRests(v: Boolean) = context.dataStore.edit { it[SettingsKeys.collapseRests] = v }
    suspend fun setKeepAwake(v: Boolean) = context.dataStore.edit { it[SettingsKeys.keepAwake] = v }
    suspend fun setLayoutMode(v: String) = context.dataStore.edit { it[SettingsKeys.layoutMode] = v }
    suspend fun setStaffSize(v: Double) = context.dataStore.edit { it[SettingsKeys.staffSize] = v }
    suspend fun setHonorBreaks(v: Boolean) = context.dataStore.edit { it[SettingsKeys.honorBreaks] = v }
    suspend fun setShowInvisible(v: Boolean) = context.dataStore.edit { it[SettingsKeys.showInvisible] = v }
    suspend fun setHiddenStaves(v: Set<String>) = context.dataStore.edit { it[SettingsKeys.hiddenStaves] = v }
    suspend fun setClefOverrides(v: Set<String>) = context.dataStore.edit { it[SettingsKeys.clefOverrides] = v }
    suspend fun setPageTapHintDismissed() = context.dataStore.edit { it[SettingsKeys.pageTapHintDismissed] = true }
    suspend fun setShowSeekBar(v: Boolean) = context.dataStore.edit { it[SettingsKeys.showSeekBar] = v }
    suspend fun setAutoFollow(v: Boolean) = context.dataStore.edit { it[SettingsKeys.autoFollowEnabled] = v }
    suspend fun setPageTurnButtonsVisible(v: Boolean) =
        context.dataStore.edit { it[SettingsKeys.pageTurnButtonsVisible] = v }
    suspend fun setA4ReferenceHz(v: Double) = context.dataStore.edit { it[SettingsKeys.a4ReferenceHz] = v }
    suspend fun setRepeatMode(v: String) = context.dataStore.edit { it[SettingsKeys.repeatMode] = v }
    suspend fun setPlaylistContinuationMode(v: String) =
        context.dataStore.edit { it[SettingsKeys.playlistContinuationMode] = v }

    suspend fun setLibrarySortOrder(v: String) =
        context.dataStore.edit { it[SettingsKeys.librarySortOrder] = v }

    suspend fun setCrashReporting(v: Boolean) =
        context.dataStore.edit { it[SettingsKeys.crashReportingEnabled] = v }

    suspend fun setAnalytics(v: Boolean) =
        context.dataStore.edit { it[SettingsKeys.analyticsEnabled] = v }

    /**
     * One-shot flip of Picture-in-Picture from opt-in to opt-out. PiP shipped defaulting to off and
     * almost nobody found the switch, so the default is now on and every install that predates the
     * flip is force-enabled once — including the few users who had explicitly turned it off. The
     * [SettingsKeys.pipForcedOnApplied] flag makes sure it runs exactly once, so a user who turns PiP
     * off *after* the migration keeps it off forever. Same rule as iOS
     * `PictureInPictureOptOutMigration`, expressed against DataStore.
     */
    suspend fun applyPictureInPictureOptOutMigration() = context.dataStore.edit { p ->
        if (p[SettingsKeys.pipForcedOnApplied] != true) {
            p[SettingsKeys.pipEnabled] = true
            p[SettingsKeys.pipForcedOnApplied] = true
        }
    }

    /**
     * Persists the whole annotation pen setup (four pen widths, eraser width, selected tool) in one
     * edit. `s.penWidths.getOrElse` (not a bare index) because [AnnotationToolState]'s constructor
     * doesn't constrain `penWidths.size` to 4 — a hypothetical caller passing a shorter list must not
     * crash the write; it degrades to that slot's shipping default instead.
     */
    suspend fun setAnnotationToolState(s: AnnotationToolState) = context.dataStore.edit { p ->
        SettingsKeys.annotationPenWidths.forEachIndexed { i, key ->
            p[key] = s.penWidths.getOrElse(i) { AnnotationWidths.PEN_DEFAULTS[i] }
        }
        p[SettingsKeys.annotationEraserWidth] = s.eraserWidth
        p[SettingsKeys.annotationSelectedTool] = encodeAnnotationTool(s.selected)
    }
}

/**
 * Encodes [AnnotationTool] as the wire string persisted under [SettingsKeys.annotationSelectedTool]:
 * `"pen:<colorIndex>"` for [AnnotationTool.Pen], `"eraser"` for [AnnotationTool.Eraser]. Inverse of
 * [decodeAnnotationTool]. `internal` (not `private`) so the unit test can exercise the round trip
 * directly, matching the minimal-visibility convention used across the repo.
 */
internal fun encodeAnnotationTool(tool: AnnotationTool): String = when (tool) {
    is AnnotationTool.Pen -> "pen:${tool.colorIndex}"
    AnnotationTool.Eraser -> "eraser"
}

/**
 * Decodes the wire string written by [encodeAnnotationTool] back into an [AnnotationTool]. TOTAL:
 * `null`, `""`, a bare numeric string with no `"pen:"` prefix (e.g. `"2"`), any other unrecognized
 * string, or a `"pen:<n>"` whose index falls outside the four pen-width slots (`0..3`) all degrade to
 * `AnnotationTool.Pen(0)` rather than throwing — a persisted value from a future preset table, a
 * corrupted prefs blob, or a first-launch absence must never crash composition. The `startsWith`
 * guard is load-bearing: without it, `removePrefix("pen:")` is a no-op on a prefix-less string, so a
 * bare `"2"` would silently parse as `Pen(2)` instead of falling through to the unrecognized-string
 * case the spec requires.
 */
internal fun decodeAnnotationTool(raw: String?): AnnotationTool {
    if (raw == "eraser") return AnnotationTool.Eraser
    if (raw != null && raw.startsWith("pen:")) {
        raw.removePrefix("pen:").toIntOrNull()
            ?.takeIf { it in AnnotationWidths.PEN_DEFAULTS.indices }
            ?.let { return AnnotationTool.Pen(it) }
    }
    return AnnotationTool.Pen(0)
}

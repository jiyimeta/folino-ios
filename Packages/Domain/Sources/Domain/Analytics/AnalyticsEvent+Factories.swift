import UtilityCore

/// A multiplicity tag for actions that can apply to one item or a bulk selection.
public enum AnalyticsActionMode: String, Sendable {
    case single
    case bulk
}

extension AnalyticsEvent {
    // MARK: Library

    public static func scoreImported(
        format: ScoreFormat, source: String, isDuplicate: Bool, museScoreMajorVersion: Int?,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_imported", parameters: [
            "format": .string(format.analyticsValue),
            "source": .string(source),
            "is_duplicate": .bool(isDuplicate),
            "musescore_version": .string(museScoreMajorVersion.map(String.init) ?? "unknown"),
        ])
    }

    public static func scoreImportFailed(format: String, reason: String) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "score_import_failed",
            parameters: ["format": .string(format), "reason": .string(reason)],
        )
    }

    public static func scoreOpened(from: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "select_content",
            parameters: ["content_type": .string("score"), "from": .string(from.rawValue)],
        )
    }

    public static func sortChanged(_ sort: ScoreItemSort) -> AnalyticsEvent {
        AnalyticsEvent(name: "sort_changed", parameters: ["sort_order": .string(sort.analyticsValue)])
    }

    /// `count` is logged raw (events-first: bucket at analysis time, not at collection — see the analytics spec).
    public static func scoreDeleted(source: AnalyticsSource, mode: AnalyticsActionMode, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_deleted", parameters: [
            "source": .string(source.rawValue), "mode": .string(mode.rawValue), "count": .int(count),
        ])
    }

    public static func favoriteToggled(
        enabled: Bool, source: AnalyticsSource, mode: AnalyticsActionMode,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "favorite_toggled", parameters: [
            "enabled": .bool(enabled), "source": .string(source.rawValue), "mode": .string(mode.rawValue),
        ])
    }

    public static func search() -> AnalyticsEvent {
        AnalyticsEvent(name: "search")
    }

    // MARK: Playlists & tags

    public static func playlistCreated(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_created", parameters: ["source": .string(source.rawValue)])
    }

    public static func playlistRenamed(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_renamed", parameters: ["source": .string(source.rawValue)])
    }

    public static func playlistDeleted(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_deleted", parameters: ["source": .string(source.rawValue)])
    }

    public static func playlistReordered() -> AnalyticsEvent {
        AnalyticsEvent(name: "playlist_reordered")
    }

    public static func scoreAddedToPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "score_added_to_playlist",
            parameters: ["source": .string(source.rawValue), "count": .int(count)],
        )
    }

    public static func scoreRemovedFromPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "score_removed_from_playlist",
            parameters: ["source": .string(source.rawValue), "count": .int(count)],
        )
    }

    public static func tagCreated(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_created", parameters: ["source": .string(source.rawValue)])
    }

    public static func tagRenamed(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_renamed", parameters: ["source": .string(source.rawValue)])
    }

    public static func tagDeleted(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "tag_deleted", parameters: ["source": .string(source.rawValue)])
    }

    public static func tagAssigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "tag_assigned",
            parameters: ["source": .string(source.rawValue), "count": .int(count)],
        )
    }

    public static func tagUnassigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "tag_unassigned",
            parameters: ["source": .string(source.rawValue), "count": .int(count)],
        )
    }

    // MARK: Reader / playback

    public static func playbackStarted(layoutMode: ReaderLayoutMode, from: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "playback_started", parameters: [
            "layout_mode": .string(layoutMode.analyticsValue), "from": .string(from.rawValue),
        ])
    }

    public static func playbackCompleted() -> AnalyticsEvent {
        AnalyticsEvent(name: "playback_completed")
    }

    public static func playbackControl(action: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "playback_control", parameters: ["action": .string(action)])
    }

    public static func repeatModeChanged(_ mode: RepeatMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "repeat_mode_changed", parameters: ["mode": .string(mode.analyticsValue)])
    }

    public static func tempoChanged(direction: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "tempo_changed", parameters: ["direction": .string(direction)])
    }

    public static func layoutModeChanged(_ mode: ReaderLayoutMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "layout_mode_changed", parameters: ["mode": .string(mode.analyticsValue)])
    }

    /// The reader switched between the notation folino read out of a PDF and the original pages. Tells us whether the
    /// original is a curiosity or something people actually read from.
    public static func displaySourceChanged(_ source: ReaderDisplaySource) -> AnalyticsEvent {
        AnalyticsEvent(name: "display_source_changed", parameters: ["source": .string(source.rawValue)])
    }

    public static func transposeChanged(direction: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "transpose_changed", parameters: ["direction": .string(direction)])
    }

    public static func scoreInfoOpened(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_info_opened", parameters: ["source": .string(source.rawValue)])
    }

    public static func annotationStarted() -> AnalyticsEvent {
        AnalyticsEvent(name: "annotation_started")
    }

    // MARK: Share

    public static func share(method: String, source: AnalyticsSource, mode: AnalyticsActionMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "share", parameters: [
            "content_type": .string("score"), "method": .string(method),
            "source": .string(source.rawValue), "mode": .string(mode.rawValue),
        ])
    }

    /// Logged once the hand-off resolves, not on tap — matching how `share` is instrumented. `target` carries the
    /// companion app's short name so a future second companion needs no new event, only a new `CompanionTarget` case.
    public static func companionHandoff(
        target: CompanionTarget,
        outcome: CompanionHandoffOutcome,
        source: AnalyticsSource,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "companion_handoff", parameters: [
            "target": .string(target.rawValue), "outcome": .string(outcome.rawValue),
            "source": .string(source.rawValue),
        ])
    }

    // MARK: Settings / app

    public static func settingChanged(key: String, value: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "setting_changed", parameters: ["key": .string(key), "value": .string(value)])
    }

    public static func settingsOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "settings_opened")
    }

    // MARK: Screen views

    /// Manual `screen_view` (reserved GA4 recommended event). `screen_name` (`AnalyticsParameterScreenName`) is the
    /// only param; Firebase surfaces it as `firebase_screen` in BigQuery. Firebase fills the rest. Emitted from each
    /// top-level screen's `onAppear` because SwiftUI screen views are not auto-collected. Do not use the reserved
    /// `firebase_` prefix for custom params — Firebase silently drops them.
    public static func screen(_ screen: AnalyticsScreen) -> AnalyticsEvent {
        AnalyticsEvent(name: "screen_view", parameters: ["screen_name": .string(screen.rawValue)])
    }

    // MARK: Launch snapshots (events-first replacements for user properties)

    /// One-per-launch snapshot of durable settings. Raw values — bucket at analysis time. "Current settings per user"
    /// is the latest `settings_snapshot`; `setting_changed` adds the change history.
    public static func settingsSnapshot(
        metronome: Bool,
        pictureInPicture: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibles: Bool,
        keepScreenAwake: Bool,
        showSeekBar: Bool,
        repeatMode: RepeatMode,
        playlistContinuation: PlaylistContinuationMode,
        a4ReferenceHz: Double,
        layoutMode: ReaderLayoutMode,
        crashReportingEnabled: Bool,
        soundfontPreset: String,
        // Defaulted ONLY so the Android `AnalyticsBridge` — whose signature is a `@WireletExpose` wire contract —
        // keeps compiling until Android grows the setting. `false` is the honest value for a platform that cannot
        // turn it on. Drop the default once the Kotlin side passes it.
        showAllMeasureNumbers: Bool = false,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "settings_snapshot", parameters: [
            "metronome_enabled": .bool(metronome),
            "picture_in_picture_enabled": .bool(pictureInPicture),
            "collapse_multi_measure_rests": .bool(collapseMultiMeasureRests),
            "show_invisible_elements": .bool(showInvisibles),
            "keep_screen_awake": .bool(keepScreenAwake),
            "show_seek_bar": .bool(showSeekBar),
            "repeat_mode": .string(repeatMode.analyticsValue),
            "playlist_continuation": .string(playlistContinuation.analyticsValue),
            "a4_reference_hz": .double(a4ReferenceHz),
            "layout_mode": .string(layoutMode.analyticsValue),
            "crash_reporting_enabled": .bool(crashReportingEnabled),
            "soundfont_preset": .string(soundfontPreset),
            "show_all_measure_numbers": .bool(showAllMeasureNumbers),
        ])
    }

    /// One-per-launch snapshot of library composition. Raw counts (metrics) — bucket at analysis time. Replaces the
    /// former library-count user properties.
    public static func librarySnapshot(
        total: Int, mscz2: Int, mscz3: Int, mscz4: Int,
        musicXML: Int, midi: Int, pdf: Int,
        playlistCount: Int, tagCount: Int, favoriteCount: Int,
    ) -> AnalyticsEvent {
        AnalyticsEvent(name: "library_snapshot", parameters: [
            "score_count_total": .int(total),
            "score_count_mscz2": .int(mscz2),
            "score_count_mscz3": .int(mscz3),
            "score_count_mscz4": .int(mscz4),
            "score_count_musicxml": .int(musicXML),
            "score_count_midi": .int(midi),
            "score_count_pdf": .int(pdf),
            "playlist_count": .int(playlistCount),
            "tag_count": .int(tagCount),
            "favorite_count": .int(favoriteCount),
        ])
    }

    /// One-per-changed-score launch snapshot (§7 of the 2026-08-05 per-score-prefs spec). THE mechanic: a parameter is
    /// included only when the underlying value is non-`nil` (non-empty for sets/dictionaries) — in BigQuery "param
    /// present" == changed and its value is the settled value. Returns `nil` for an all-untouched row so callers skip
    /// the event entirely. Carries NO score identifier by design. `master_volume_pct` / `tempo_multiplier_pct` round to
    /// 10% steps and `screen_width_pt` snaps to a breakpoint — a documented exception to the raw-params policy; these
    /// are continuous values whose sub-bucket precision carries no decision value.
    ///
    /// `repeatMode` / `abRepeat` deliberately have no parameter: repeat mode is a global sticky setting already covered
    /// by `settings_snapshot` / `repeat_mode_changed`, and neither has a per-score user-intent question to answer.
    public static func scorePrefs(_ prefs: ReaderPreferences, screenWidthPt: Double) -> AnalyticsEvent? {
        var params: [String: AnalyticsValue] = [:]
        if let staffSize = prefs.staffSize { params["staff_size"] = .int(Int(staffSize.rounded())) }
        if let honorBreaks = prefs.honorLayoutBreaks { params["honor_layout_breaks"] = .bool(honorBreaks) }
        if let volume = prefs.masterVolume { params["master_volume_pct"] = .int(percentBucket(volume)) }
        if let transpose = prefs.transposeSemitones { params["transpose_semitones"] = .int(transpose) }
        if let tempo = prefs.tempoMultiplier { params["tempo_multiplier_pct"] = .int(percentBucket(tempo)) }
        if let a4 = prefs.a4ReferenceHz { params["a4_reference_hz"] = .int(Int(a4.rounded())) }
        let userHidden = prefs.hiddenStaves.subtracting(prefs.authoredHiddenStaves)
        if !userHidden.isEmpty { params["hidden_staff_count"] = .int(userHidden.count) }
        let userRevealed = prefs.authoredHiddenStaves.subtracting(prefs.hiddenStaves)
        if !userRevealed.isEmpty { params["revealed_staff_count"] = .int(userRevealed.count) }
        if !prefs.staffProgramOverrides.isEmpty {
            params["program_override_count"] = .int(prefs.staffProgramOverrides.count)
        }
        if !prefs.staffVolumeOverrides.isEmpty {
            params["volume_override_count"] = .int(prefs.staffVolumeOverrides.count)
        }
        if !prefs.staffClefOverrides.isEmpty {
            params["clef_override_count"] = .int(prefs.staffClefOverrides.count)
        }
        guard !params.isEmpty else { return nil }
        params["screen_width_pt"] = .int(screenWidthBucket(screenWidthPt))
        return AnalyticsEvent(name: "score_prefs", parameters: params)
    }

    /// A `1.0`-is-unity multiplier as a percentage rounded to 10% steps (`0.55` -> `60`).
    private static func percentBucket(_ multiplier: Double) -> Int {
        Int((multiplier * 10).rounded()) * 10
    }

    /// Effective-width bucket: the largest breakpoint that does not exceed the width (below 320 reports 320). Owned by
    /// Domain so iOS (points) and Android (dp) share one table.
    public static func screenWidthBucket(_ widthPt: Double) -> Int {
        let breakpoints = [1366, 1024, 834, 744, 430, 390, 375, 320]
        return breakpoints.first { Double($0) <= widthPt } ?? 320
    }

    /// Launch-time enumeration: one event per LIVE score whose row has any explicitly-set preference. Trashed scores
    /// are excluded so the numerator matches `library_snapshot.score_count_total`.
    public static func scorePrefsEvents(
        allPreferences: [ReaderPreferences],
        liveScoreItemIDs: Set<ScoreItemID>,
        screenWidthPt: Double,
    ) -> [AnalyticsEvent] {
        allPreferences
            .filter { liveScoreItemIDs.contains($0.scoreItemID) }
            .compactMap { scorePrefs($0, screenWidthPt: screenWidthPt) }
    }

    /// Session-level annotation summary, emitted when annotation mode exits. Replaces the per-stroke
    /// `annotation_ink_committed` so the pipeline is not flooded with one event per stroke.
    public static func annotationEnded(strokes: Int, durationSec: Double) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "annotation_ended",
            parameters: ["ink_strokes": .int(strokes), "duration_sec": .double(durationSec)],
        )
    }
}

import UtilityCore

/// The one-per-launch snapshot events, split out of `AnalyticsEvent+Factories.swift` only because that file
/// had reached SwiftLint's 400-line ceiling. They are the events-first replacement for user properties:
/// each is emitted once per launch and carries raw values, because this codebase buckets at analysis time.
extension AnalyticsEvent {
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
        // turn it on.
        // PARITY(android): settings_snapshot.show_all_measure_numbers — pass it from the AnalyticsBridge and drop
        //   the default here, so the parameter stops reading as "off" for every Android launch

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
        if let staffSize = prefs.staffSize {
            params["staff_size"] = .int(Int(staffSize.rounded()))
        }
        if let honorBreaks = prefs.honorLayoutBreaks {
            params["honor_layout_breaks"] = .bool(honorBreaks)
        }
        if let volume = prefs.masterVolume {
            params["master_volume_pct"] = .int(percentBucket(volume))
        }
        if let transpose = prefs.transposeSemitones {
            params["transpose_semitones"] = .int(transpose)
        }
        if let tempo = prefs.tempoMultiplier {
            params["tempo_multiplier_pct"] = .int(percentBucket(tempo))
        }
        if let a4 = prefs.a4ReferenceHz {
            params["a4_reference_hz"] = .int(Int(a4.rounded()))
        }
        let userHidden = prefs.hiddenStaves.subtracting(prefs.authoredHiddenStaves)
        if !userHidden.isEmpty {
            params["hidden_staff_count"] = .int(userHidden.count)
        }
        let userRevealed = prefs.authoredHiddenStaves.subtracting(prefs.hiddenStaves)
        if !userRevealed.isEmpty {
            params["revealed_staff_count"] = .int(userRevealed.count)
        }
        if !prefs.stripProgramOverrides.isEmpty {
            params["program_override_count"] = .int(prefs.stripProgramOverrides.count)
        }
        if !prefs.stripVolumeOverrides.isEmpty {
            params["volume_override_count"] = .int(prefs.stripVolumeOverrides.count)
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
}

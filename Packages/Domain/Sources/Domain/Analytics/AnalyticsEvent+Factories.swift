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

    /// Session-level annotation summary, emitted when annotation mode exits. Replaces the per-stroke
    /// `annotation_ink_committed` so the pipeline is not flooded with one event per stroke.
    public static func annotationEnded(strokes: Int, durationSec: Double) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "annotation_ended",
            parameters: ["ink_strokes": .int(strokes), "duration_sec": .double(durationSec)],
        )
    }
}

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

    /// `count` is always bucketed through `countBucket` before it reaches analytics: the privacy contract forbids
    /// raw counts. The factories own the bucketing so a caller can never accidentally leak a precise magnitude.
    public static func scoreDeleted(source: AnalyticsSource, mode: AnalyticsActionMode, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_deleted", parameters: [
            "source": .string(source.rawValue), "mode": .string(mode.rawValue), "count": .string(countBucket(count)),
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
            parameters: ["source": .string(source.rawValue), "count": .string(countBucket(count))],
        )
    }

    public static func scoreRemovedFromPlaylist(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "score_removed_from_playlist",
            parameters: ["source": .string(source.rawValue), "count": .string(countBucket(count))],
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
            parameters: ["source": .string(source.rawValue), "count": .string(countBucket(count))],
        )
    }

    public static func tagUnassigned(source: AnalyticsSource, count: Int) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "tag_unassigned",
            parameters: ["source": .string(source.rawValue), "count": .string(countBucket(count))],
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

    public static func transposeChanged(direction: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "transpose_changed", parameters: ["direction": .string(direction)])
    }

    public static func scoreInfoOpened(source: AnalyticsSource) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_info_opened", parameters: ["source": .string(source.rawValue)])
    }

    public static func annotationStarted() -> AnalyticsEvent {
        AnalyticsEvent(name: "annotation_started")
    }

    public static func annotationInkCommitted() -> AnalyticsEvent {
        AnalyticsEvent(name: "annotation_ink_committed")
    }

    // MARK: Share

    public static func share(method: String, source: AnalyticsSource, mode: AnalyticsActionMode) -> AnalyticsEvent {
        AnalyticsEvent(name: "share", parameters: [
            "content_type": .string("score"), "method": .string(method),
            "source": .string(source.rawValue), "mode": .string(mode.rawValue),
        ])
    }

    // MARK: Settings / app

    public static func settingChanged(key: String, value: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "setting_changed", parameters: ["key": .string(key), "value": .string(value)])
    }

    public static func settingsOpened() -> AnalyticsEvent {
        AnalyticsEvent(name: "settings_opened")
    }
}

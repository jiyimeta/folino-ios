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

    /// Logged when the scratch-creation form successfully builds and saves a new blank score.
    ///
    /// `template` says where the instrumentation came from: a ready-made ensemble's id (`"solo-piano"`,
    /// `"string-quartet"`, …), `"cloned"` when it was copied wholesale from an existing score, or `"custom"` once the
    /// user has hand-edited the list — a hand-edit is what makes the ensemble no longer that template's. `nil` (logged
    /// as `"unknown"`, matching `scoreImported`'s missing version) is for a caller with no wizard context.
    ///
    /// `partCount` is logged raw — events-first: bucket at analysis time, not at collection.
    public static func scoreCreated(template: String?, partCount: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_created", parameters: [
            "template": .string(template ?? "unknown"), "part_count": .int(partCount),
        ])
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

    // MARK: Editing

    /// A part added, removed or reordered from the instruments sheet — `action` is `"add"`, `"remove"` or `"reorder"`.
    /// Which instrument was involved is deliberately not carried (M2 spec §8): the question this answers is whether
    /// people edit an ensemble after creating it, not what they fill it with.
    public static func scorePartsEdited(action: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_parts_edited", parameters: ["action": .string(action)])
    }

    /// A key or time signature written or dropped from one of the signature sheets — `kind` is `"key"` or `"time"`,
    /// `action` is `"set"` or `"remove"`. Which key, or which meter, is deliberately not carried, for the reason
    /// `scorePartsEdited` gives: the question is whether people change signatures after creating a score, not what
    /// they change them to.
    public static func scoreSignatureChanged(kind: String, action: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_signature_changed", parameters: [
            "kind": .string(kind), "action": .string(action),
        ])
    }

    /// A rehearsal mark written, renamed or removed in the editor. `action` is `"set"` (the bar carried no mark),
    /// `"rename"` (it did) or `"remove"`. The score sees one write either way, but naming a bar for the first time
    /// and renaming one that was already named are different user acts, and collected data cannot be split apart
    /// afterwards — so the two are separated at the source.
    public static func scoreRehearsalMarkEdited(action: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_rehearsal_mark_edited", parameters: [
            "action": .string(action),
        ])
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

    /// Logged when the drift guard trips; `reason` is `page_count`, `page_size`, or `unreadable_base_pdf`.
    public static func annotatedExportDrifted(reason: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "annotated_export_drifted", parameters: ["reason": .string(reason)])
    }

    /// Logged when a stroke's Apple ink payload could not be built. The stroke still exports as a plain `/Ink`
    /// annotation, so this is a silent capability loss rather than a failure the user sees.
    public static func annotatedExportAKEncodeFailed(count: Int) -> AnalyticsEvent {
        AnalyticsEvent(name: "annotated_export_ak_encode_failed", parameters: ["count": .int(count)])
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

    // MARK: Annotation

    /// Session-level annotation summary, emitted when annotation mode exits. Replaces the per-stroke
    /// `annotation_ink_committed` so the pipeline is not flooded with one event per stroke.
    public static func annotationEnded(strokes: Int, durationSec: Double) -> AnalyticsEvent {
        AnalyticsEvent(
            name: "annotation_ended",
            parameters: ["ink_strokes": .int(strokes), "duration_sec": .double(durationSec)],
        )
    }
}

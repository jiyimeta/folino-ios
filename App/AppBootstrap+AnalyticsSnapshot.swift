import Domain
import Foundation
import Persistence
import UIKit
import UtilityCore

/// The once-per-launch analytics snapshot, split out of `AppBootstrap.swift` to keep that file under the SwiftLint
/// `file_length` budget.
extension AppBootstrap {
    /// Emits the launch snapshot events (events-first; no user properties): `library_snapshot`, `settings_snapshot`,
    /// then one `score_prefs` per changed score. Called once after the repository is ready so library counts are
    /// current. Behind the consent gate inside the sink. Sort order is not persisted (held in-memory in
    /// `ScoreListViewModel`), so it is intentionally not part of the settings snapshot — sort is captured by the
    /// `sort_changed` event instead.
    func pushAnalyticsSnapshot(repository: LiveScoreLibraryRepository) async {
        guard let analytics else { return }
        let defaults = UserDefaults.standard

        analytics.log(AnalyticsLibrarySnapshot.event(
            items: repository.scoreItems,
            playlistCount: repository.playlists.count,
            tagCount: repository.tags.count,
        ))

        func boolSetting(_ key: String, default defaultValue: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        let repeatMode = RepeatMode(rawValue: defaults.string(forKey: ReaderGlobalSettingsKey.repeatMode) ?? "")
            ?? .off
        let continuation = PlaylistContinuationMode(
            rawValue: defaults.string(forKey: ReaderGlobalSettingsKey.playlistContinuationMode) ?? "",
        ) ?? .playThrough
        let layoutMode = ReaderLayoutMode(rawValue: defaults.string(forKey: ReaderGlobalSettingsKey.layoutMode) ?? "")
            ?? .page
        let a4 = defaults.object(forKey: ReaderGlobalSettingsKey.a4ReferenceHz) as? Double ?? A4Reference.standardHz

        analytics.log(.settingsSnapshot(
            metronome: boolSetting(ReaderGlobalSettingsKey.metronomeEnabled, default: false),
            pictureInPicture: boolSetting(ReaderGlobalSettingsKey.pictureInPictureEnabled, default: true),
            collapseMultiMeasureRests: boolSetting(ReaderGlobalSettingsKey.collapseMultiMeasureRests, default: false),
            showInvisibles: boolSetting(ReaderGlobalSettingsKey.showInvisibleElements, default: false),
            keepScreenAwake: boolSetting(ReaderGlobalSettingsKey.keepScreenAwakeEnabled, default: true),
            showSeekBar: boolSetting(ReaderGlobalSettingsKey.showSeekBarEnabled, default: true),
            repeatMode: repeatMode,
            playlistContinuation: continuation,
            a4ReferenceHz: a4,
            layoutMode: layoutMode,
            crashReportingEnabled: boolSetting(PrivacySettingsKey.crashReportingEnabled, default: true),
            soundfontPreset: museScoreGeneralProvider?.currentPreset.rawValue
                ?? SoundfontPreset.lightweight.rawValue,
        ))

        // One event per changed score (spec 2026-08-05), last so the two aggregate snapshots are already in flight.
        for event in await Self.scorePrefsEvents(
            repository: repository,
            screenWidthPt: Self.effectiveWindowWidthPt(),
            crashReporter: crashReporter ?? NoopCrashReporter(),
        ) {
            analytics.log(event)
        }
    }

    /// The launch `score_prefs` events for the current library. Split out of `pushAnalyticsSnapshot` so the two
    /// App-owned decisions here are testable; parameter selection and bucketing stay in the Domain factory, which
    /// Android calls too.
    ///
    /// - The live-item filter comes from `scoreItems`, which excludes soft-deleted rows — that keeps the event count
    ///   comparable with `library_snapshot.score_count_total`. `allReaderPreferences()` deliberately returns rows for
    ///   trashed scores as well, so the filtering has to happen here.
    /// - A failed read degrades to "no events": the same best-effort stance as the surrounding snapshots, none of
    ///   which may fail a launch. It is recorded as a non-fatal, though — `allReaderPreferences()` is a whole-table
    ///   read, so one bad row zeroes every `score_prefs` event for the launch, and silence would make that
    ///   indistinguishable downstream from "these users customize nothing".
    static func scorePrefsEvents(
        repository: some ScoreLibraryRepository,
        screenWidthPt: Double,
        crashReporter: any CrashReporter,
    ) async -> [AnalyticsEvent] {
        let allPreferences: [ReaderPreferences]
        do {
            allPreferences = try await repository.allReaderPreferences()
        } catch {
            crashReporter.record(error: error)
            return []
        }
        return AnalyticsEvent.scorePrefsEvents(
            allPreferences: allPreferences,
            liveScoreItemIDs: Set(repository.scoreItems.map(\.id)),
            screenWidthPt: screenWidthPt,
        )
    }

    /// Effective app-window width in points at emission time — Split View / Stage Manager narrow it below the screen
    /// width, which is exactly the layout-relevant fact. Falls back to the screen bounds before a key window exists;
    /// a width of 0 buckets to the smallest breakpoint, an acceptable degenerate case for a headless launch.
    ///
    /// The foreground scene is chosen deliberately: `connectedScenes` is a `Set`, so with two folino windows open its
    /// iteration order is arbitrary and unstable across launches — taking any scene could measure the background
    /// window. `screen_width_pt` is the axis every other `score_prefs` param is read against, so a wrong bucket here
    /// silently mis-reads the whole row.
    private static func effectiveWindowWidthPt() -> Double {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        if let window { return window.bounds.width }
        return Double(scene?.screen.bounds.width ?? 0)
    }
}

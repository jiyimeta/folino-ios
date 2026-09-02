// PARITY(macos): App Group–backed launch tasks — the Mac schedules none of the five (share drain, playlists index,
//   shared-SoundFont reconciliation, capability stamp, cross-app score drain). macOS has no Share Extension, its App
//   Group container is team-ID-prefixed, and `App/Mac/Info.plist` declares no `CFBundleURLTypes`, so the app cannot
//   receive the `folino://open-score` hand-off the capability stamp advertises. Sub-project Ⅷ adds entitlements and a
//   sandbox; whoever does that decides which of these the Mac should join, and must add the URL type before letting
//   the stamp claim the one-tap route.

import Domain
import ImportExport
import UtilityCore

/// macOS counterpart of `App/iOS/SharedContainerTasks.swift`. See the file-header marker above for why every member
/// declines instead of degrading through an unavailable-container check: the Mac must not schedule these tasks even
/// once entitlements make the container resolvable. `@MainActor` to mirror the iOS type's signature.
@MainActor
enum SharedContainerTasks {
    static func playlistsIndexWriter() -> PlaylistsIndexWriter? {
        nil
    }

    static func makeIncomingShareCoordinator(
        importer: any ScoreFileImporter,
        repository: any ScoreLibraryRepository,
        duplicateResolver: any ImportDuplicateResolver,
        analytics: any Analytics,
        crashReporter: any CrashReporter,
    ) -> IncomingShareCoordinator? {
        nil
    }

    static func reconcileSoundfontToSharedContainer() {}

    static func stampCapabilities(appVersion: String) {}

    static func makeIncomingScoreCoordinator(
        importer: any ScoreFileImporter,
        analytics: any Analytics,
        crashReporter: any CrashReporter,
    ) -> IncomingScoreCoordinator? {
        nil
    }
}

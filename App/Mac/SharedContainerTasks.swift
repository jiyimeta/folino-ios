// PARITY(macos): cross-app App Group tasks — the Mac schedules three of the five, and will not schedule the other
//   two ever. Deferred gaps: shared-SoundFont reconciliation, the capability stamp, and the cross-app score drain.
//   They need the App Group entitlement, a `CFBundleURLTypes` declaration for `folino://open-score`, and the
//   removal of `AppPaths.sharedContainer`'s macOS gate (Ⅷ §2) — all three together, never separately.
//   NOT gaps, and never will be: the playlists index and the incoming-share drain. Both exist to serve a Share
//   Extension, and macOS has none.

import Domain
import ImportExport
import UtilityCore

/// macOS counterpart of `App/iOS/SharedContainerTasks.swift`. See the file-header marker above for the split between
/// the two tasks that decline forever (no Share Extension to serve) and the three that decline only until the
/// deferred work above lands. `@MainActor` to mirror the iOS type's signature.
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

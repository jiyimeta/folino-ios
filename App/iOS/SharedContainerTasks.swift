import Domain
import Foundation
import ImportExport
import ImportExportAppGroup
import Soundfonts
import UtilityCore

/// Every App Group–backed startup task, on iOS: publishing the playlists index the Share Extension's picker reads,
/// draining what the Share Extension staged before this launch, reconciling the shared SoundFont, stamping the
/// cross-app capability file, and draining `folino://open-score` hand-offs. The bootstrap reaches the shared container
/// only through this type, so the Mac counterpart in `App/Mac/SharedContainerTasks.swift` can decline all five by
/// construction rather than by relying on `containerURL(...)` happening to return `nil`.
///
/// `@MainActor` because `IncomingShareCoordinator.init` is.
@MainActor
enum SharedContainerTasks {
    static func playlistsIndexWriter() -> PlaylistsIndexWriter? {
        AppGroupPaths.container().map { PlaylistsIndexWriter(appGroupContainer: $0) }
    }

    static func makeIncomingShareCoordinator(
        importer: any ScoreFileImporter,
        repository: any ScoreLibraryRepository,
        duplicateResolver: any ImportDuplicateResolver,
        analytics: any Analytics,
        crashReporter: any CrashReporter,
    ) -> IncomingShareCoordinator? {
        AppGroupPaths.container().map { container in
            IncomingShareCoordinator(
                importer: importer,
                repository: repository,
                appGroupContainer: container,
                clock: SystemClock(),
                duplicateResolver: duplicateResolver,
                analytics: analytics,
                crashReporter: crashReporter,
            )
        }
    }

    /// Move-then-dedup the high-quality SoundFont into the shared App Group container, so folino and VocalTuner keep
    /// one copy instead of two. No-op when the container is unavailable — the resolvers then read the legacy private
    /// path, which is also where the file already is.
    static func reconcileSoundfontToSharedContainer() {
        guard let shared = AppPaths.sharedSoundfontsDirectory else { return }
        SoundfontContainerMigration().reconcile(
            fileName: SoundfontPreset.highQuality.fileName,
            sharedDirectory: shared,
            legacyDirectory: AppPaths.legacySoundfontsDirectory,
            minimumValidByteSize: AppBootstrap.soundfontMinimumValidByteSize,
        )
    }

    /// Publishes `folino/capabilities.json` in the shared App Group so sibling apps can tell that this build accepts
    /// the one-tap `folino://open-score` hand-off; a sibling that finds no stamp falls back to a share sheet. Written
    /// on every launch so the advertised app and protocol versions follow whatever build is installed. Best-effort: a
    /// missing container, or a write that fails, only costs the sibling its one-tap path.
    static func stampCapabilities(appVersion: String) {
        guard let container = AppPaths.sharedContainer else { return }
        try? CapabilityStampWriter(sharedContainer: container).stamp(appVersion: appVersion)
    }

    /// Builds the drain for hand-offs a sibling staged in the shared App Group. `nil` when that container is
    /// unavailable, in which case the `folino://open-score` route quietly does nothing — the sibling has no capability
    /// stamp to read either, so it never offers one-tap in the first place.
    static func makeIncomingScoreCoordinator(
        importer: any ScoreFileImporter,
        analytics: any Analytics,
        crashReporter: any CrashReporter,
    ) -> IncomingScoreCoordinator? {
        AppPaths.sharedContainer.map { container in
            IncomingScoreCoordinator(
                importer: importer,
                sharedContainer: container,
                analytics: analytics,
                crashReporter: crashReporter,
            )
        }
    }
}

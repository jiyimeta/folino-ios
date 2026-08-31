import Domain
import Foundation
import ImportExport
import ImportExportAppGroup
import UtilityCore

/// App Group–backed startup tasks for iOS: publishing the playlists index the Share Extension's picker reads, and
/// building the coordinator that drains files the Share Extension staged before this launch. Mac counterpart in
/// `App/Mac/SharedContainerTasks.swift` schedules neither — see that file for why.
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
}

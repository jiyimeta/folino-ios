// PARITY(macos): App Group–backed share drain and playlist index — macOS has no Share Extension and its App Group
//   container is team-ID-prefixed, so the Mac bootstrap schedules neither. Revisit if a Mac share destination or a
//   sibling-app hand-off ever needs the shared container.

import Domain
import ImportExport
import UtilityCore

/// macOS counterpart of `App/iOS/SharedContainerTasks.swift`. See the file-header marker above for why both factory
/// methods simply return `nil` here instead of degrading through an unavailable-container check like the rest of the
/// App Group–backed code does. `@MainActor` to mirror the iOS type's signature.
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
}

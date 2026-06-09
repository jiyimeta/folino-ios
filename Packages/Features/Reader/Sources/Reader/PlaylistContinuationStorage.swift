import Domain
import Foundation

/// Reads the global, sticky `PlaylistContinuationMode` from `UserDefaults` for imperative (non-`@AppStorage`) code such
/// as `ReaderViewModel`. Mirrors how `A4ReferenceModel` reads its global default. The inspector and Settings write this
/// same key through `@AppStorage(ReaderGlobalSettingsKey.playlistContinuationMode)`.
enum PlaylistContinuationStorage {
    static func current(_ defaults: UserDefaults = .standard) -> PlaylistContinuationMode {
        defaults.string(forKey: ReaderGlobalSettingsKey.playlistContinuationMode)
            .flatMap(PlaylistContinuationMode.init(rawValue:)) ?? .playThrough
    }
}

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

/// Reads / writes the global, sticky `RepeatMode` in `UserDefaults` for imperative code (`RepeatModel`). The inspector
/// and Settings write this same key through `@AppStorage(ReaderGlobalSettingsKey.repeatMode)`. Only the mode is global;
/// the A–B endpoints stay per-score in `ReaderPreferences.abRepeat`.
enum RepeatModeStorage {
    static func current(_ defaults: UserDefaults = .standard) -> RepeatMode {
        defaults.string(forKey: ReaderGlobalSettingsKey.repeatMode)
            .flatMap(RepeatMode.init(rawValue:)) ?? .off
    }

    static func set(_ mode: RepeatMode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: ReaderGlobalSettingsKey.repeatMode)
    }
}

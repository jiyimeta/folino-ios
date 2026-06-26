import Foundation

/// Resolves on-disk locations the app uses. Centralized so AppBootstrap and any future migrations agree on layout.
enum AppPaths {
    static var documentsRoot: URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable — sandbox is broken")
        }
        return url
    }

    static var scoresDirectory: URL {
        documentsRoot.appending(path: "Scores")
    }

    static var databaseURL: URL {
        documentsRoot.appending(path: "Folino.sqlite")
    }

    /// The cross-app shared App Group container. Soundfonts (and, later, scores) live here so Folino and VocalTuner
    /// share one copy. See `docs/superpowers/specs/2026-06-26-shared-soundfont-app-group-design.md`.
    static let sharedAppGroupIdentifier = "group.com.KeyNumber.shared"

    /// `<shared container>/Soundfonts/`. `nil` when the container is unavailable (entitlement/provisioning gap) — the
    /// resolver and migration both degrade to `legacySoundfontsDirectory` so playback never breaks.
    static var sharedSoundfontsDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier)?
            .appending(path: "Soundfonts")
    }

    /// The pre-sharing private location (`Library/Application Support/Soundfonts/`). Migration source + degraded
    /// fallback. Application Support (not Caches) so iOS storage cleanup does not evict a 206 MB opted-in asset.
    static var legacySoundfontsDirectory: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable — sandbox is broken")
        }
        return url.appending(path: "Soundfonts")
    }

    /// Primary soundfont location used by the provider/resolver: the shared container when available, else legacy.
    static var soundfontsDirectory: URL {
        sharedSoundfontsDirectory ?? legacySoundfontsDirectory
    }

    static var shareTempDirectory: URL {
        documentsRoot.appending(path: "ShareTmp")
    }
}

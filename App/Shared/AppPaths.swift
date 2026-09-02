import Foundation
import ImportExportAppGroup

/// Resolves on-disk locations the app uses. Centralized so AppBootstrap and any future migrations agree on layout.
enum AppPaths {
    // PARITY(macos): document root — this is the pre-sandbox location (`~/Library/Application Support/folino/`),
    //   not the App Sandbox container. Sub-project Ⅷ moves it into the sandbox with a security-scoped bookmark;
    //   Application Support is already where that container's equivalent maps, so nothing here has to move twice
    //   in spirit.
    /// Root of the app's document storage: `~/Documents` on iOS (sandboxed), `~/Library/Application Support/folino/`
    /// on macOS (this app is not yet sandboxed there, so `.documentDirectory` would resolve to the user's real
    /// `~/Documents` — the wrong place for app-managed data to live, and to be recursively cleaned by
    /// `AppBootstrap.prepareDirectories()` on every launch).
    static var documentsRoot: URL {
        #if os(iOS)
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable — sandbox is broken")
        }
        return url
        #else
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            fatalError("Application Support directory unavailable")
        }
        let url = base.appending(path: "folino")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #endif
    }

    static var scoresDirectory: URL {
        documentsRoot.appending(path: "Scores")
    }

    static var databaseURL: URL {
        documentsRoot.appending(path: "Folino.sqlite")
    }

    /// The cross-app shared App Group container. Soundfonts and incoming cross-app score hand-offs live here so Folino
    /// and VocalTuner share one copy. See `docs/superpowers/specs/2026-06-26-shared-soundfont-app-group-design.md`.
    static let sharedAppGroupIdentifier = SharedAppGroupIDs.identifier

    /// Root of the cross-app shared App Group container, or `nil` when it is unavailable (entitlement/provisioning
    /// gap). Callers that write into it — the incoming-score drain, the capability stamp — degrade to doing nothing.
    static var sharedContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier)
    }

    /// `<shared container>/Soundfonts/`. `nil` when the container is unavailable (entitlement/provisioning gap) — the
    /// resolver and migration both degrade to `legacySoundfontsDirectory` so playback never breaks.
    ///
    /// Cross-app SoundFont sharing is **iOS-only by design**: App Groups have no clean Android equivalent
    /// (`sharedUserId` is deprecated; scoped storage / ContentProvider don't give two apps a shared private container),
    /// so on Android each app keeps its own copy — `containerURL` returns `nil` and this degrades to the per-app
    /// private directory automatically. See the spec's "Android / cross-platform parity" section.
    static var sharedSoundfontsDirectory: URL? {
        sharedContainer?.appending(path: "Soundfonts")
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

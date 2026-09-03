import Foundation
import ImportExportAppGroup

/// Resolves on-disk locations the app uses. Centralized so AppBootstrap and any future migrations agree on layout.
enum AppPaths {
    /// Root of the app's document storage: `~/Documents` on iOS (sandboxed), `~/Library/Application Support/folino/`
    /// on macOS. The Mac app is sandboxed too (`2026-09-03-macos-distribution-design.md` §3), so `FileManager`
    /// resolves that same `.applicationSupportDirectory` call inside the app's container —
    /// `~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application Support/folino/` — not the visible,
    /// shared `~/Library/Application Support/folino/`. Application Support, not `.documentDirectory`, is used on
    /// purpose either way: this directory holds app-managed data (the library database, the scores directory, the
    /// share staging directory) that `AppBootstrap.prepareDirectories()` recursively cleans on every launch — not
    /// something to keep alongside the user's own Documents.
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

    /// Root of the cross-app shared App Group container, or `nil` when it is unavailable. Callers that write into it
    /// — the incoming-score drain, the capability stamp — degrade to doing nothing.
    ///
    /// **`nil` on macOS, unconditionally.** The Mac does not join the App Group: `App/Mac/SharedContainerTasks.swift`
    /// declines every App Group launch task by construction, and this is the other half of that decision. It has to
    /// be explicit rather than inherited from a missing entitlement, because macOS does not behave like iOS here — an
    /// unsandboxed Mac app gets a real path back from `containerURL(forSecurityApplicationGroupIdentifier:)` whether
    /// or not it holds the entitlement, and creates the directory on demand. That is how the Mac's SoundFonts ended
    /// up in `~/Library/Group Containers/…` (measured 2026-09-03) by way of `AudioStackFactory`, which is shared
    /// code. Under the App Sandbox that path is not writable, and `AppBootstrap.prepareDirectories()` creates the
    /// SoundFont directory with `try` — so leaving this to chance is a failed launch, not a missing SoundFont.
    ///
    /// The sub-project that wires the cross-app tasks removes this gate and adds the entitlement together.
    static var sharedContainer: URL? {
        #if os(macOS)
        nil
        #else
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier)
        #endif
    }

    /// `<shared container>/Soundfonts/`. `nil` when the container is unavailable — on macOS that is `sharedContainer`
    /// returning `nil` unconditionally, by design (see its doc comment); on iOS/Android it is a genuine
    /// entitlement/provisioning gap. Either way the resolver and migration degrade to `legacySoundfontsDirectory` so
    /// playback never breaks.
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

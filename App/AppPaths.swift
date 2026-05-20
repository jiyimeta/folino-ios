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

    /// `Library/Application Support/Soundfonts/`. The MuseScore_General download lands here. Application Support
    /// (not Caches) so iOS storage cleanup does not silently evict a 206 MB asset the user opted to keep. Excluded from
    /// iCloud / iTunes backup at directory creation time (see `AppBootstrap.prepareDirectories`).
    static var soundfontsDirectory: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable — sandbox is broken")
        }
        return url.appending(path: "Soundfonts")
    }

    static var shareTempDirectory: URL {
        documentsRoot.appending(path: "ShareTmp")
    }
}

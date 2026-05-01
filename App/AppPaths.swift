import Foundation

/// Resolves on-disk locations the app uses. Centralized so AppBootstrap and
/// any future migrations agree on layout.
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

    static var soundfontCacheDirectory: URL {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            fatalError("Caches directory unavailable — sandbox is broken")
        }
        return url.appending(path: "Soundfonts")
    }
}

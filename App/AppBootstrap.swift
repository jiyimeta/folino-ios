import Foundation
import Observation

@MainActor
@Observable
final class AppBootstrap {
    private(set) var isReady = false

    func start() {
        try? FileManager.default.createDirectory(at: AppPaths.scoresDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: AppPaths.soundfontCacheDirectory, withIntermediateDirectories: true
        )
        isReady = true
    }
}

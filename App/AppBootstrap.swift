import Domain
import Foundation
import Observation
import Persistence
import ScoreFiles

@MainActor
@Observable
final class AppBootstrap {
    private(set) var isReady = false
    private(set) var failure: Error?

    private(set) var database: AppDatabase?
    private(set) var repository: LiveScoreLibraryRepository?
    private(set) var gateway: LiveScoreFileGateway?
    private(set) var importer: LiveScoreFileImporter?

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.scoresDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: AppPaths.soundfontCacheDirectory, withIntermediateDirectories: true
            )
            let database = try AppDatabase(databaseURL: AppPaths.databaseURL)
            let repository = LiveScoreLibraryRepository(
                database: database,
                scoresDirectory: AppPaths.scoresDirectory
            )
            let gateway = LiveScoreFileGateway()
            let importer = LiveScoreFileImporter(
                gateway: gateway,
                repository: repository,
                scoresDirectory: AppPaths.scoresDirectory
            )

            self.database = database
            self.repository = repository
            self.gateway = gateway
            self.importer = importer

            Task { [weak self] in
                do {
                    try await repository.refresh()
                    self?.isReady = true
                } catch {
                    self?.failure = error
                }
            }
        } catch {
            failure = error
        }
    }
}

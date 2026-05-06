import Audio
import Domain
import Foundation
import Observation
import Persistence
import ScoreFiles
import Soundfonts

@MainActor
@Observable
final class AppBootstrap {
    private(set) var isReady = false
    private(set) var failure: Error?

    private(set) var database: AppDatabase?
    private(set) var repository: LiveScoreLibraryRepository?
    private(set) var gateway: LiveScoreFileGateway?
    private(set) var importer: LiveScoreFileImporter?
    private(set) var playbackController: LivePlaybackController?
    private(set) var reachability: LiveNetworkReachability?
    private(set) var soundfontResolver: MuseScoreSF2Resolver?
    private(set) var presetCatalog: BundledSF2PresetCatalog?
    private(set) var shareService: LiveScoreShareService?

    /// Single-slot queue for an incoming URL received via `.onOpenURL`.
    /// Last-wins: a second URL arriving before the first is consumed
    /// overwrites it. v1 only opens one file at a time.
    private(set) var pendingIncomingURL: URL?

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.scoresDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: AppPaths.soundfontCacheDirectory, withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: AppPaths.shareTempDirectory)
            try FileManager.default.createDirectory(
                at: AppPaths.shareTempDirectory, withIntermediateDirectories: true
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
            shareService = LiveScoreShareService(
                scoresDirectory: AppPaths.scoresDirectory,
                shareTempDirectory: AppPaths.shareTempDirectory,
                gateway: gateway
            )
            // `MuseScoreSF2Resolver` conforms to all three protocols
            // (`SheetMusicAudio.SoundfontResolver`, `Domain.SoundfontResolver`,
            // `Domain.PrecisePatchProbe`); one instance satisfies every slot.
            let soundfontResolver = MuseScoreSF2Resolver(
                cacheDirectory: AppPaths.soundfontCacheDirectory
            )
            self.soundfontResolver = soundfontResolver
            if let bundleSF2URL = Bundle.main.url(
                forResource: "MuseScore_General", withExtension: "sf2", subdirectory: "Sounds"
            ) {
                presetCatalog = try? BundledSF2PresetCatalog(sf2URL: bundleSF2URL)
            }
            playbackController = LivePlaybackController(
                soundfontResolver: soundfontResolver,
                domainResolver: soundfontResolver,
                precisionProbe: soundfontResolver
            )
            reachability = LiveNetworkReachability()

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

    func acceptIncomingURL(_ url: URL) {
        pendingIncomingURL = url
    }

    func consumePendingIncomingURL() -> URL? {
        let url = pendingIncomingURL
        pendingIncomingURL = nil
        return url
    }
}

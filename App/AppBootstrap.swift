import Audio
import AVFoundation
import Domain
import Foundation
import ImportExport
import ImportExportAppGroup
import Observation
import Persistence
import ScoreFiles
import Soundfonts
import UtilityCore

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
    private(set) var incomingShareCoordinator: IncomingShareCoordinator?
    let shareDuplicateResolver = ShareDuplicateResolver()

    /// Single-slot queue for an incoming URL received via `.onOpenURL`. Last-wins: a second URL arriving before the
    /// first is consumed overwrites it. v1 only opens one file at a time.
    private(set) var pendingIncomingURL: URL?

    /// Single-slot for an incoming share token. Last-wins.
    private(set) var pendingShareToken: UUID?
    private(set) var pendingShareOpenAfter = false

    func start() {
        do {
            configureAudioSession()
            try prepareDirectories()
            let appGroupContainer = AppGroupPaths.container()
            let writer: PlaylistsIndexWriter? = appGroupContainer.map {
                PlaylistsIndexWriter(appGroupContainer: $0)
            }
            let database = try AppDatabase(databaseURL: AppPaths.databaseURL)
            let repository = LiveScoreLibraryRepository(
                database: database,
                scoresDirectory: AppPaths.scoresDirectory,
                playlistsIndexPublisher: writer,
            )
            let gateway = LiveScoreFileGateway()
            let importer = LiveScoreFileImporter(
                gateway: gateway,
                repository: repository,
                scoresDirectory: AppPaths.scoresDirectory,
            )
            let shareCoordinator: IncomingShareCoordinator? = appGroupContainer.map { container in
                IncomingShareCoordinator(
                    importer: importer,
                    repository: repository,
                    appGroupContainer: container,
                    clock: SystemClock(),
                    duplicateResolver: shareDuplicateResolver,
                )
            }

            self.database = database
            self.repository = repository
            self.gateway = gateway
            self.importer = importer
            incomingShareCoordinator = shareCoordinator
            installAudioStack(gateway: gateway)
            reachability = LiveNetworkReachability()

            Task { [weak self] in
                do {
                    try await repository.refresh()
                    // Best-effort purge of trash items past the 30-day retention window. Failures don't block
                    // readiness.
                    try? await repository.pruneScoreItemsDeleted(
                        before: Date().addingTimeInterval(-Self.recentlyDeletedRetention),
                    )
                    // Publish current playlists so the Share Extension's picker is populated on first use.
                    if let writer { writer.publish(playlists: repository.playlists) }
                    // Drain any tokens queued by the Share Extension before this launch.
                    await self?.incomingShareCoordinator?.drain(token: nil)
                    self?.isReady = true
                } catch {
                    self?.failure = error
                }
            }
        } catch {
            failure = error
        }
    }

    private func installAudioStack(gateway: LiveScoreFileGateway) {
        // `MuseScoreSF2Resolver` conforms to all three protocols (`SheetMusicAudio.SoundfontResolver`,
        // `Domain.SoundfontResolver`, `Domain.PrecisePatchProbe`); one instance satisfies every slot.
        let soundfontResolver = MuseScoreSF2Resolver(
            cacheDirectory: AppPaths.soundfontCacheDirectory,
        )
        self.soundfontResolver = soundfontResolver
        if let bundleSF2URL = Bundle.main.url(
            forResource: "MuseScore_General", withExtension: "sf2", subdirectory: "Sounds",
        ) {
            presetCatalog = try? BundledSF2PresetCatalog(sf2URL: bundleSF2URL)
        }
        let audioExporter = LiveScoreAudioExporter(
            soundfontResolver: soundfontResolver,
            domainResolver: soundfontResolver,
            metronomeEnabled: {
                UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.metronomeEnabled)
            },
        )
        shareService = LiveScoreShareService(
            scoresDirectory: AppPaths.scoresDirectory,
            shareTempDirectory: AppPaths.shareTempDirectory,
            gateway: gateway,
            audioExporter: audioExporter,
        )
        playbackController = LivePlaybackController(
            soundfontResolver: soundfontResolver,
            domainResolver: soundfontResolver,
            precisionProbe: soundfontResolver,
        )
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: AppPaths.scoresDirectory, withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: AppPaths.soundfontCacheDirectory, withIntermediateDirectories: true,
        )
        try? FileManager.default.removeItem(at: AppPaths.shareTempDirectory)
        try FileManager.default.createDirectory(
            at: AppPaths.shareTempDirectory, withIntermediateDirectories: true,
        )
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [],
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func acceptIncomingURL(_ url: URL) {
        if let parsed = ShareTokenURL.parse(url) {
            pendingShareToken = parsed.token
            pendingShareOpenAfter = parsed.openAfter
            return
        }
        pendingIncomingURL = url
    }

    func consumePendingIncomingURL() -> URL? {
        let url = pendingIncomingURL
        pendingIncomingURL = nil
        return url
    }

    /// Best-effort prune of trashed items that exceeded the 30-day retention. Called from `AppShellView` when the scene
    /// becomes active so a long-running session also enforces the retention window without a relaunch.
    func pruneRecentlyDeletedIfNeeded() {
        guard let repository else { return }
        Task {
            try? await repository.pruneScoreItemsDeleted(
                before: Date().addingTimeInterval(-Self.recentlyDeletedRetention),
            )
        }
    }

    func consumePendingShareToken() -> (UUID, Bool)? {
        guard let token = pendingShareToken else { return nil }
        let pair = (token, pendingShareOpenAfter)
        pendingShareToken = nil
        pendingShareOpenAfter = false
        return pair
    }

    /// Trash retention window: 30 days expressed as seconds.
    private static let recentlyDeletedRetention: TimeInterval = 30 * 24 * 60 * 60
}

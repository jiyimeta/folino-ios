import Analytics
import Audio
import CrashReporting
import Domain
import Foundation
import ImportExport
import ImportExportAppGroup
import Observation
import Persistence
import Reader
import ScoreFiles
import Soundfonts
import UtilityCore

/// One-shot flag guarding `AnnotationFormatMigrator`: once every stored annotation layer has been rewritten to the
/// neutral InkStroke format, this is set and the migration is skipped on subsequent launches.
private enum AnnotationMigrationKey {
    static let neutralFormatMigrated = "annotation.neutralFormatMigrated.v1"
}

@MainActor
@Observable
final class AppBootstrap {
    private(set) var isReady = false
    private(set) var failure: Error?

    /// Guards `start()` against re-entry. `start()` is driven from a `.task` on `AppShellView` inside the
    /// `WindowGroup`, which SwiftUI may run more than once — every iPad scene gets its own `AppShellView` + `.task`
    /// sharing this single bootstrap, and a view-identity re-evaluation re-fires `.task` too. A second `start()` would
    /// call `FirebaseApp.configure()` twice (the `appWasConfiguredTwice` FATAL seen in Crashlytics) and rebuild the
    /// whole adapter stack. Matches the per-process idempotency the sibling `.task` coordinators already document.
    private var didStart = false

    private(set) var database: AppDatabase?
    /// The shared annotation save policy, backed by `LiveAnnotationStore` (an `AnnotationBlobStore`). Injected into
    /// every `ReaderViewModel` so iOS and Android drive the same debounce / empty→delete / assembly cadence.
    private(set) var annotationCoordinator: AnnotationSaveCoordinator?
    private(set) var repository: LiveScoreLibraryRepository?
    private(set) var gateway: LiveScoreFileGateway?
    private(set) var originalStore: LiveScoreOriginalStore?
    private(set) var importer: LiveScoreFileImporter?
    private(set) var playbackController: LivePlaybackController?
    /// Stateless PDF → playable-score parser (ssm OMR). Always available on Apple, no async setup, so
    /// it's a plain constant rather than a slot filled during `start()`.
    let pdfPlaybackParser = LivePDFPlaybackParser()
    /// Reads a PDF into notation and writes it as `.mscz`. Built once in `start()` over `pdfPlaybackParser` and the
    /// gateway, then handed to both the importer (convert on import) and every Reader session (convert a PDF imported
    /// before folino could read one, and re-read on request).
    private(set) var pdfScoreConversion: PDFScoreConversion?
    private(set) var reachability: LiveNetworkReachability?
    private(set) var museScoreGeneralProvider: LiveMuseScoreGeneralProvider?
    private(set) var soundfontResolver: GMSoundfontResolver?
    private(set) var shareService: LiveScoreShareService?
    private(set) var metadataReader: LiveScoreMetadataReader?
    private(set) var incomingShareCoordinator: IncomingShareCoordinator?
    /// Drains cross-app score hand-offs (`folino://open-score`) staged by a sibling app in the shared App Group.
    /// `nil` when that container is unavailable, in which case the route degrades to doing nothing.
    private(set) var incomingScoreCoordinator: IncomingScoreCoordinator?
    private(set) var crashReporter: (any CrashReporter)?
    private(set) var analytics: (any Analytics)?
    let shareDuplicateResolver = ShareDuplicateResolver()

    /// Single-slot queue for an incoming URL received via `.onOpenURL`. Last-wins: a second URL arriving before the
    /// first is consumed overwrites it. v1 only opens one file at a time.
    private(set) var pendingIncomingURL: URL?

    /// Single-slot for an incoming share token. Last-wins.
    private(set) var pendingShareToken: UUID?
    private(set) var pendingShareOpenAfter = false

    /// Single-slot for a cross-app `folino://open-score` token. Last-wins, mirroring `pendingShareToken`. The token is
    /// a `String` because the cross-app contract only promises a string, not a `UUID`.
    private(set) var pendingOpenScoreToken: String?
    private(set) var pendingOpenScoreOpenAfter = false

    func start() {
        guard !didStart else { return }
        didStart = true
        let crashEnabled = UserDefaults.standard
            .object(forKey: PrivacySettingsKey.crashReportingEnabled) as? Bool ?? true
        crashReporter = FirebaseCrashReporter.configure(collectionEnabled: crashEnabled)
        configureAnalytics()
        // Before any Reader / Settings view reads the key, so the first launch after the update already sees PiP on.
        PictureInPictureOptOutMigration.apply(to: .standard)
        do {
            try prepareDirectories()
            cleanupLegacySoundfontCacheIfNeeded()
            reconcileSoundfontToSharedContainerIfNeeded()
            stampSharedCapabilities()
            let appGroupContainer = AppGroupPaths.container()
            let writer: PlaylistsIndexWriter? = appGroupContainer.map {
                PlaylistsIndexWriter(appGroupContainer: $0)
            }
            let database = try AppDatabase(databaseURL: AppPaths.databaseURL)
            let annotationStore = LiveAnnotationStore(database: database)
            let repository = LiveScoreLibraryRepository(
                database: database,
                scoresDirectory: AppPaths.scoresDirectory,
                playlistsIndexPublisher: writer,
            )
            let gateway = LiveScoreFileGateway(crashReporter: crashReporter ?? NoopCrashReporter())
            let originalStore = LiveScoreOriginalStore(scoresDirectory: AppPaths.scoresDirectory, gateway: gateway)
            pdfScoreConversion = makePDFScoreConversion(gateway: gateway)
            let importer = LiveScoreFileImporter(
                gateway: gateway,
                repository: repository,
                scoresDirectory: AppPaths.scoresDirectory,
                pdfConversion: pdfScoreConversion,
            )
            let shareCoordinator: IncomingShareCoordinator? = appGroupContainer.map { container in
                IncomingShareCoordinator(
                    importer: importer,
                    repository: repository,
                    appGroupContainer: container,
                    clock: SystemClock(),
                    duplicateResolver: shareDuplicateResolver,
                    analytics: analytics ?? NoopAnalytics(),
                    crashReporter: crashReporter ?? NoopCrashReporter(),
                )
            }

            incomingScoreCoordinator = makeIncomingScoreCoordinator(importer: importer)

            self.database = database
            annotationCoordinator = AnnotationSaveCoordinator(store: annotationStore)
            self.repository = repository
            self.gateway = gateway
            self.originalStore = originalStore
            self.importer = importer
            incomingShareCoordinator = shareCoordinator
            installAudioStack(gateway: gateway)
            reachability = LiveNetworkReachability()
            migrateAnnotationFormatIfNeeded(database: database)

            Task { [weak self] in await self?.finishStartup(repository: repository, writer: writer) }
        } catch {
            failure = error
        }
    }

    /// Async body of the post-refresh startup sequence, extracted to keep `start()` within the SwiftLint
    /// `function_body_length` limit. Runs on the main actor (inherited from the `Task` that calls it).
    private func finishStartup(repository: LiveScoreLibraryRepository, writer: PlaylistsIndexWriter?) async {
        do {
            try await repository.refresh()
            // One-shot: carry the last-opened score's (formerly per-score) repeat mode into the new global key.
            await migrateRepeatModeFromLastOpenedScoreIfNeeded(repository)
            // Best-effort purge of trash items past the 30-day retention window. Failures don't block readiness.
            try? await repository.pruneScoreItemsDeleted(
                before: Date().addingTimeInterval(-Self.recentlyDeletedRetention),
            )
            // Publish current playlists so the Share Extension's picker is populated on first use.
            if let writer { writer.publish(playlists: repository.playlists) }
            // Drain any tokens queued by the Share Extension before this launch.
            _ = await incomingShareCoordinator?.drain(token: nil)
            await pushAnalyticsSnapshot(repository: repository)
            isReady = true
        } catch {
            failure = error
        }
    }

    private func configureAnalytics() {
        let enabled = UserDefaults.standard
            .object(forKey: PrivacySettingsKey.analyticsEnabled) as? Bool ?? true
        analytics = FirebaseAnalyticsClient.make(collectionEnabled: enabled)
    }

    private func installAudioStack(gateway: LiveScoreFileGateway) {
        let reclaimer = SharedSoundfontReclaimer(
            soundfontsDirectory: AppPaths.soundfontsDirectory,
            soundfontFileName: SoundfontPreset.highQuality.fileName,
            minimumValidByteSize: Self.soundfontMinimumValidByteSize,
            ownBundleId: Bundle.main.bundleIdentifier ?? "com.KeyNumber.Folino",
            ownDisplayName: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "folino",
            siblings: Self.soundfontSiblings,
            installedChecker: UIKitInstalledAppChecker(),
        )
        let provider = LiveMuseScoreGeneralProvider(
            targetDirectory: AppPaths.soundfontsDirectory, reclaimer: reclaimer,
        )
        museScoreGeneralProvider = provider
        let resolver = GMSoundfontResolver(provider: provider)
        soundfontResolver = resolver
        let clickProvider = BundledMetronomeClickProvider()
        let audioExporter = LiveScoreAudioExporter(
            soundfontResolver: resolver,
            metronomeClickProvider: clickProvider,
            metronomeEnabled: {
                UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.metronomeEnabled)
            },
        )
        shareService = LiveScoreShareService(
            scoresDirectory: AppPaths.scoresDirectory,
            shareTempDirectory: AppPaths.shareTempDirectory,
            gateway: gateway,
            audioExporter: audioExporter,
            pdfRenderer: CoreGraphicsPDFRenderer(),
        )
        metadataReader = LiveScoreMetadataReader(
            gateway: gateway,
            scoresDirectory: AppPaths.scoresDirectory,
        )
        playbackController = LivePlaybackController(
            soundfontResolver: resolver,
            metronomeClickProvider: clickProvider,
        )
        provider.reconcileSharedSoundfontMarkersAtLaunch()
    }

    /// One-shot cleanup of the pre-GM per-patch SF2 cache. Old versions stored split-bank soundfonts at
    /// `Library/Caches/Soundfonts/` (filenames like `000_073.sf2`, `128_000.sf2`). The current GM stack reads only
    /// `Library/Application Support/Soundfonts/MuseScore_General.sf2`, so the legacy directory is dead weight after an
    /// in-place update — potentially hundreds of megabytes depending on how many patches the user played.
    ///
    /// Gated behind a UserDefaults flag rather than running unconditionally on every launch: if a future version
    /// reintroduces `Library/Caches/Soundfonts/` for any reason, this cleanup won't keep clobbering it. A new key
    /// (e.g. `legacySoundfontCacheCleanupV2DidRun`) can opt that future scenario back into a one-shot wipe.
    private func cleanupLegacySoundfontCacheIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.legacySoundfontCacheCleanupDidRunKey) else { return }
        if let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: cachesURL.appending(path: "Soundfonts"))
        }
        defaults.set(true, forKey: Self.legacySoundfontCacheCleanupDidRunKey)
    }

    private static let legacySoundfontCacheCleanupDidRunKey = "soundfont.legacyCacheCleanupDidRun"
    static let soundfontMinimumValidByteSize: Int64 = 150 * 1024 * 1024
    static let soundfontSiblings: [SiblingApp] = [
        SiblingApp(bundleId: "com.KeyNumber.VocalTuner", urlScheme: "vocaltuner", displayName: "VocalTuner"),
    ]

    /// One-shot migration of the repeat mode from per-score to global. The repeat mode used to be stored per-score in
    /// `ReaderPreferences`; it is now a single sticky value in `UserDefaults`. On the first launch after that change we
    /// seed the global value from the most-recently-opened score so the user's last repeat choice carries over instead
    /// of silently resetting to off. Gated on the global key being absent, so it runs exactly once and never clobbers a
    /// value the user has since changed.
    private func migrateRepeatModeFromLastOpenedScoreIfNeeded(_ repository: LiveScoreLibraryRepository) async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ReaderGlobalSettingsKey.repeatMode) == nil else { return }
        let lastOpened = repository.scoreItems
            .filter { $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
        // Default to `.off` for a fresh install (no history) or if the score's preferences can't be read — writing the
        // key either way marks the migration done so it doesn't re-check on every launch.
        var mode = RepeatMode.off
        if let lastOpened, let prefs = try? await repository.loadReaderPreferences(for: lastOpened.id) {
            mode = prefs.repeatMode
        }
        defaults.set(mode.rawValue, forKey: ReaderGlobalSettingsKey.repeatMode)
    }

    /// One-shot rewrite of every stored `AnnotationLayer`'s drawings from legacy PKDrawing bytes to the neutral
    /// InkStroke format. Read-both decoding (in Reader) already keeps the app correct against old data, so this
    /// runs off the main thread and is allowed to silently fail — on error the flag stays unset and the next launch
    /// retries. Gated on a `UserDefaults` flag so a completed migration never re-scans the table.
    private func migrateAnnotationFormatIfNeeded(database: AppDatabase) {
        guard !UserDefaults.standard.bool(forKey: AnnotationMigrationKey.neutralFormatMigrated) else { return }
        let migrator = AnnotationFormatMigrator(database: database)
        Task.detached(priority: .utility) {
            do {
                _ = try await migrator.migrate(transcode: { data in
                    InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(data)
                })
                UserDefaults.standard.set(true, forKey: AnnotationMigrationKey.neutralFormatMigrated)
            } catch {
                // Non-fatal: read-both keeps the app correct; retry on next launch (flag stays unset).
            }
        }
    }

    /// Move-then-dedup the high-quality SoundFont into the shared App Group container before the provider is built.
    /// No-op when the container is unavailable (resolvers degrade to the legacy private path).
    private func reconcileSoundfontToSharedContainerIfNeeded() {
        guard let shared = AppPaths.sharedSoundfontsDirectory else { return }
        SoundfontContainerMigration().reconcile(
            fileName: SoundfontPreset.highQuality.fileName,
            sharedDirectory: shared,
            legacyDirectory: AppPaths.legacySoundfontsDirectory,
            minimumValidByteSize: Self.soundfontMinimumValidByteSize,
        )
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: AppPaths.scoresDirectory, withIntermediateDirectories: true,
        )
        var soundfontsDir = AppPaths.soundfontsDirectory
        try FileManager.default.createDirectory(at: soundfontsDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? soundfontsDir.setResourceValues(values)
        try? FileManager.default.removeItem(at: AppPaths.shareTempDirectory)
        try FileManager.default.createDirectory(
            at: AppPaths.shareTempDirectory, withIntermediateDirectories: true,
        )
    }

    func acceptIncomingURL(_ url: URL) {
        if let parsed = ShareTokenURL.parse(url) {
            pendingShareToken = parsed.token
            pendingShareOpenAfter = parsed.openAfter
            return
        }
        if let parsed = OpenScoreURL.parse(url) {
            pendingOpenScoreToken = parsed.token
            pendingOpenScoreOpenAfter = parsed.openAfter
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

    func consumePendingOpenScoreToken() -> (String, Bool)? {
        guard let token = pendingOpenScoreToken else { return nil }
        let pair = (token, pendingOpenScoreOpenAfter)
        pendingOpenScoreToken = nil
        pendingOpenScoreOpenAfter = false
        return pair
    }

    /// Trash retention window: 30 days expressed as seconds.
    private static let recentlyDeletedRetention: TimeInterval = 30 * 24 * 60 * 60
}

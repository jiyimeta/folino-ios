import Audio
import Domain
import Foundation
import Reader
import ScoreFiles
import Soundfonts

/// Builds the iOS audio and sharing adapter stack for `AppBootstrap`. The Mac counterpart in
/// `App/Mac/AudioStackFactory.swift` builds the same stack from the same adapters, differing in exactly one:
/// `UIKitInstalledAppChecker`, which has no Mac sibling app to probe and is replaced there by `NoSiblingAppChecker`.
///
/// `@MainActor` because `LiveMuseScoreGeneralProvider.init` and `LivePlaybackController.init` both are — this method
/// used to run inline inside `AppBootstrap` (itself `@MainActor`), so the isolation has to travel with the
/// extraction.
@MainActor
enum AudioStackFactory {
    static func make(
        gateway: LiveScoreFileGateway,
        scoresDirectory: URL,
        shareTempDirectory: URL,
    ) -> AudioStack {
        let reclaimer = SharedSoundfontReclaimer(
            soundfontsDirectory: AppPaths.soundfontsDirectory,
            soundfontFileName: SoundfontPreset.highQuality.fileName,
            minimumValidByteSize: AppBootstrap.soundfontMinimumValidByteSize,
            ownBundleId: Bundle.main.bundleIdentifier ?? "com.KeyNumber.Folino",
            ownDisplayName: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "folino",
            siblings: AppBootstrap.soundfontSiblings,
            installedChecker: UIKitInstalledAppChecker(),
        )
        let provider = LiveMuseScoreGeneralProvider(
            targetDirectory: AppPaths.soundfontsDirectory, reclaimer: reclaimer,
        )
        let resolver = GMSoundfontResolver(provider: provider)
        let clickProvider = BundledMetronomeClickProvider()
        let audioExporter = LiveScoreAudioExporter(
            soundfontResolver: resolver,
            metronomeClickProvider: clickProvider,
            metronomeEnabled: {
                UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.metronomeEnabled)
            },
        )
        let shareService = LiveScoreShareService(
            scoresDirectory: scoresDirectory,
            shareTempDirectory: shareTempDirectory,
            gateway: gateway,
            audioExporter: audioExporter,
            pdfRenderer: CoreGraphicsPDFRenderer(),
        )
        let metadataReader = LiveScoreMetadataReader(
            gateway: gateway,
            scoresDirectory: scoresDirectory,
        )
        let playbackController = LivePlaybackController(
            soundfontResolver: resolver,
            metronomeClickProvider: clickProvider,
        )
        return AudioStack(
            museScoreGeneralProvider: provider,
            soundfontResolver: resolver,
            shareService: shareService,
            metadataReader: metadataReader,
            playbackController: playbackController,
        )
    }
}

import Audio
import Domain
import Foundation
import Reader
import ScoreFiles
import Soundfonts

/// Builds the audio and sharing adapter stack `AppBootstrap` installs.
///
/// **One factory, not a pair.** This started as `App/iOS/AudioStackFactory.swift` and `App/Mac/AudioStackFactory.swift`
/// because the Mac then had no `LivePlaybackController` and no `LiveScoreAudioExporter` — real divergence, and spec
/// §2.4's paired-file rule is exactly for that. Un-gating both adapters collapsed the difference to a single injected
/// argument, and one injectable argument is not the "genuinely different behavior per platform" that rule licenses;
/// two 70-line files that differ in one identifier are just a place for the halves to drift apart.
///
/// `@MainActor` because `LiveMuseScoreGeneralProvider.init` and `LivePlaybackController.init` both are — this used to
/// run inline inside `AppBootstrap` (itself `@MainActor`), so the isolation travels with the extraction.
@MainActor
enum AudioStackFactory {
    /// The platform's sibling-app probe, and the whole of what differs between iOS and macOS here.
    ///
    /// iOS asks `UIApplication.canOpenURL`; macOS has no such probe and no Mac sibling app to find, so it reports
    /// nothing installed and the reclaimer falls back to this app's own opt-in state — the same answer iOS gives when
    /// no sibling is installed.
    static var platformInstalledChecker: any InstalledAppChecking {
        #if os(iOS)
        UIKitInstalledAppChecker()
        #else
        NoSiblingAppChecker()
        #endif
    }

    static func make(
        gateway: LiveScoreFileGateway,
        scoresDirectory: URL,
        shareTempDirectory: URL,
        installedChecker: any InstalledAppChecking = platformInstalledChecker,
    ) -> AudioStack {
        let reclaimer = SharedSoundfontReclaimer(
            soundfontsDirectory: AppPaths.soundfontsDirectory,
            soundfontFileName: SoundfontPreset.highQuality.fileName,
            minimumValidByteSize: AppBootstrap.soundfontMinimumValidByteSize,
            ownBundleId: Bundle.main.bundleIdentifier ?? "com.KeyNumber.Folino",
            ownDisplayName: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "folino",
            siblings: AppBootstrap.soundfontSiblings,
            installedChecker: installedChecker,
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

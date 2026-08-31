import Audio
import Domain
import Foundation
import Reader
import ScoreFiles
import Soundfonts

/// `SharedSoundfontReclaimer.installedChecker` on macOS: there is no `UIApplication.canOpenURL` sibling-app probe, and
/// no Mac sibling app to detect yet — always report nothing installed. The reclaimer then falls back to whatever this
/// app's own opt-in state says, exactly as it would on iOS with no siblings installed.
struct NoSiblingAppChecker: InstalledAppChecking {
    func isInstalled(urlScheme: String) -> Bool {
        false
    }
}

/// Builds the macOS audio and sharing adapter stack for `AppBootstrap`. Same shape as the iOS `AudioStackFactory` in
/// `App/iOS/AudioStackFactory.swift`, and now the same adapters too: `LivePlaybackController` and
/// `LiveScoreAudioExporter` are no longer iOS-gated, so the Mac gets the real ones rather than a `nil` controller and
/// an export stub. The single remaining difference is `UIKitInstalledAppChecker`, replaced here by
/// `NoSiblingAppChecker` — there is no Mac sibling app to probe for a shared soundfont.
///
/// `@MainActor` because `LiveMuseScoreGeneralProvider.init` is — mirrors the iOS factory's annotation.
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
            installedChecker: NoSiblingAppChecker(),
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

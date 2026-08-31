import Domain
import Foundation
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

// PARITY(macos): offline audio export — `LiveScoreAudioExporter` (Infrastructure/Audio) is `#if os(iOS)`-gated
//   until a later task builds the AVAudioSession-free equivalent. Until then the Mac share service is handed this
//   stub, which fails the m4a export path loudly instead of writing a silent zero-length file.
/// Stub `ScoreAudioExporter` for macOS. `LiveScoreShareService.audioExporter` stays non-optional (a Domain protocol
/// injected by the composition root), so this adapter fills the slot until the real Mac exporter lands.
struct UnavailableScoreAudioExporter: ScoreAudioExporter {
    func exportM4A(score: Score, to url: URL) throws {
        throw DomainError.audioEngineFailed(reason: "Audio export is not available on macOS yet")
    }
}

/// Builds the macOS audio and sharing adapter stack for `AppBootstrap`. Same shape as the iOS `AudioStackFactory` in
/// `App/iOS/AudioStackFactory.swift` minus the two platform-bound pieces: `UIKitInstalledAppChecker` (replaced by
/// `NoSiblingAppChecker`) and `LiveScoreAudioExporter`/`LivePlaybackController` (iOS-gated until a later task; the
/// share service gets `UnavailableScoreAudioExporter` and `playbackController` is `nil`).
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
        let shareService = LiveScoreShareService(
            scoresDirectory: scoresDirectory,
            shareTempDirectory: shareTempDirectory,
            gateway: gateway,
            audioExporter: UnavailableScoreAudioExporter(),
            pdfRenderer: CoreGraphicsPDFRenderer(),
        )
        let metadataReader = LiveScoreMetadataReader(
            gateway: gateway,
            scoresDirectory: scoresDirectory,
        )
        return AudioStack(
            museScoreGeneralProvider: provider,
            soundfontResolver: resolver,
            shareService: shareService,
            metadataReader: metadataReader,
            playbackController: nil,
        )
    }
}

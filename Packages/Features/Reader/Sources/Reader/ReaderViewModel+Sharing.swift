import Domain
import Foundation
import ScoreUI
import UtilityCore

// MARK: - Sharing

extension ReaderViewModel {
    func requestShare(format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: scoreItem, format: format)
            shareTarget = ScoreShareTarget(urls: [url])
            analytics.log(.share(method: format.analyticsValue, source: .readerOverlay, mode: .single))
        } catch {
            // Reader has no error banner yet; sharing failures are non-fatal and simply present nothing.
        }
    }

    /// Lazy format options for the share menu — same source as Library.
    func availableShareFormats() async -> [ScoreShareFormatOption] {
        await shareService.availableFormats(for: scoreItem)
    }

    /// Hand this score to VocalTuner for pitch practice. Always exports `.museScoreV4`, and re-checks availability
    /// at tap time — VocalTuner can be installed or removed while folino sits in the background.
    ///
    /// Unlike Library, the Reader has no error banner, so an export failure presents nothing; the analytics
    /// `failed` outcome is how that case stays visible.
    func requestVocalTunerHandoff() async {
        guard vocalTunerHandoff.availability != .notInstalled else {
            vocalTunerHandoff.presentAppStore()
            analytics.log(.companionHandoff(target: "vocaltuner", outcome: .appStore, source: .readerOverlay))
            return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: scoreItem, format: .museScoreV4)
            switch vocalTunerHandoff.openScore(fileURL: url, displayName: scoreItem.title) {
            case .openedViaDeepLink:
                analytics.log(.companionHandoff(target: "vocaltuner", outcome: .deepLink, source: .readerOverlay))
            case .needsShareFallback:
                shareTarget = ScoreShareTarget(urls: [url])
                analytics.log(
                    .companionHandoff(target: "vocaltuner", outcome: .shareFallback, source: .readerOverlay),
                )
            }
        } catch {
            analytics.log(.companionHandoff(target: "vocaltuner", outcome: .failed, source: .readerOverlay))
        }
    }
}

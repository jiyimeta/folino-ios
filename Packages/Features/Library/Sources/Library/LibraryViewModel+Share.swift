import Domain
import Foundation
import ScoreUI

/// Score-row and bulk share flows, plus the VocalTuner companion hand-off — split out of `LibraryViewModel` to keep
/// that file under the `file_length` budget.
extension LibraryViewModel {
    /// `source` defaults to `.scoreRowMenu` because the only single-item caller is the score row's share menu; the
    /// parameter keeps the surface explicit. `share` is logged on success (a prepared URL), not on intent — matching
    /// the Reader's share instrumentation — with `method` = the actually-chosen export format.
    func requestShare(_ item: ScoreItem, format: ScoreShareFormat, source: AnalyticsSource = .scoreRowMenu) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: format)
            shareTarget = ScoreShareTarget(urls: [url])
            analytics.log(.share(method: format.analyticsValue, source: source, mode: .single))
        } catch {
            currentError = error
        }
    }

    /// Hand this score to VocalTuner for pitch practice. Always exports `.museScoreV4` — it is the format that
    /// carries full pitch information and that VocalTuner accepts — and re-checks availability at tap time,
    /// because VocalTuner can be installed or removed while folino sits in the background.
    ///
    /// `.needsShareFallback` is not an error path: the file is already prepared, so the ordinary share sheet still
    /// gets the score across. It covers a VocalTuner that predates the receiver, a staging failure, and a deep link
    /// the system refused to open.
    func requestVocalTunerHandoff(_ item: ScoreItem, source: AnalyticsSource = .scoreRowMenu) async {
        guard vocalTunerHandoff.availability != .notInstalled else {
            vocalTunerHandoff.presentAppStore()
            analytics.log(.companionHandoff(target: .vocalTuner, outcome: .appStore, source: source))
            return
        }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: .museScoreV4)
            let result = await vocalTunerHandoff.openScore(fileURL: url, displayName: item.title)
            switch result {
            case .openedViaDeepLink:
                analytics.log(.companionHandoff(target: .vocalTuner, outcome: .deepLink, source: source))
            case .needsShareFallback:
                shareTarget = ScoreShareTarget(urls: [url])
                analytics.log(.companionHandoff(target: .vocalTuner, outcome: .shareFallback, source: source))
            }
        } catch {
            currentError = error
            analytics.log(.companionHandoff(target: .vocalTuner, outcome: .failed, source: source))
        }
    }

    func requestBulkShare(_ items: [ScoreItem], format: ScoreShareFormat) async {
        guard !items.isEmpty else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        var urls: [URL] = []
        urls.reserveCapacity(items.count)
        for item in items {
            do {
                let url = try await shareService.prepareShare(item: item, format: format)
                urls.append(url)
            } catch {
                currentError = error
                return
            }
        }
        shareTarget = ScoreShareTarget(urls: urls)
        analytics.log(.share(method: format.analyticsValue, source: .bulkEdit, mode: .bulk))
    }
}

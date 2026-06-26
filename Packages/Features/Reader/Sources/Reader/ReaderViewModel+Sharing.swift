import Domain
import Foundation
import ScoreUI

// MARK: - Sharing

extension ReaderViewModel {
    func requestShare(format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: scoreItem, format: format)
            shareTarget = ScoreShareTarget(urls: [url])
        } catch {
            // Reader has no error banner yet; sharing failures are non-fatal and simply present nothing.
        }
    }

    /// Lazy format options for the share menu — same source as Library.
    func availableShareFormats() async -> [ScoreShareFormatOption] {
        await shareService.availableFormats(for: scoreItem)
    }
}

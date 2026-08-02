import Domain
import Foundation
import PDFKit

// MARK: - Load paths (score vs. PDF)

extension ReaderViewModel {
    /// Loads a parsed-notation score into `.loaded`, computing the display-ready `visibleScore` and arming PiP.
    func loadScoreFile(url: URL) async {
        do {
            let (score, _) = try await gateway.loadScore(fileURL: url)
            await loadOrSeedPreferences(authoredHiddenStaves: score.authoredHiddenStaffAddresses)
            loadState = .loaded(score)
            recomputeVisibleScore()
            recomputeSeekTimeline()
            pipSession.armIfReady()
            await loadAnnotations()
            await updateLastOpenedAtOnce()
        } catch {
            loadState = .failed(error: error)
            visibleScore = nil
        }
    }

    /// Loads a PDF item into `.loadedPDF`: the document is opened straight from disk and handed to the PDF reader for
    /// display. Preferences and annotations still load (the annotation layer is keyed by score-item id regardless of
    /// format), and the layout mode is clamped to a PDF-allowed one. Separately, the PDF is parsed for playback in the
    /// background (best-effort OMR) so it can be played with an on-PDF cursor once the parse succeeds.
    func loadPDF(url: URL) async {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            loadState = .failed(error: DomainError.scoreParseFailed(reason: "Unreadable or empty PDF"))
            return
        }
        await loadOrSeedPreferences()
        clampLayoutModeToCapabilities()
        // An item folino couldn't read has no score side; the original is all there is.
        displaySource = .originalPDF
        loadState = .loadedPDF(doc)
        await loadAnnotations()
        await updateLastOpenedAtOnce()
        // The document is already on screen; parse it for playback in the background. Detached from `load()` so the PDF
        // displays immediately and the engine arms only when the parse lands.
        Task { [weak self] in await self?.parsePDFForPlayback(url: url) }
    }

    /// PDFs don't support horizontal mode. If the global layout mode is horizontal when a PDF opens, fall back to page
    /// so the reader never lands in an unsupported mode. Page/vertical are left untouched.
    private func clampLayoutModeToCapabilities() {
        let key = ReaderGlobalSettingsKey.layoutMode
        let raw = UserDefaults.standard.string(forKey: key) ?? ReaderLayoutMode.page.rawValue
        let mode = ReaderLayoutMode(rawValue: raw) ?? .page
        if !capabilities.availableLayoutModes.contains(mode) {
            UserDefaults.standard.set(ReaderLayoutMode.page.rawValue, forKey: key)
        }
    }
}

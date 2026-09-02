#if os(macOS)
import SheetMusicLayout
import SwiftUI

/// Horizontal mode's click handling, split out of `MacHorizontalScoreContainer` only because that file is at
/// SwiftLint's 400-line ceiling. It belongs to the container: the sticky-pane guard needs the container's viewport
/// state and its measure contexts, neither of which the strip can see.
extension MacHorizontalScoreContainer {
    /// Click-to-seek, or a selection while editing.
    ///
    /// **The click arrives from AppKit, in the strip's own unmagnified coordinates** — see
    /// `MagnifyingScoreScrollView.onClick` and `MacScoreClickMapping`. SwiftUI's own gesture geometry is unusable
    /// inside a magnified `NSScrollView`, and while this mode's single full-height strip made the damage less lurid
    /// than the page deck's (there is only one layer to catch the event), the location it reported was still scaled.
    ///
    /// **Clicks that land under the sticky pane are rejected, and that is a correctness rule rather than a polish
    /// one.** The pane is `allowsHitTesting(false)` — deliberately, so it can never swallow a scroll — which means a
    /// click on it falls straight through to the music it is covering, and that music is by definition scrolled
    /// past: clicking the frozen part labels would seek to a measure the reader cannot see. The covered span is
    /// `[scoreScrollX, stickyTrailingX]` — the same trailing edge that drives which measure the pane displays, so the
    /// guard and the pane can never disagree about where the pane ends.
    func handleClick(_ hostedPoint: CGPoint) {
        guard let document = state.document else { return }
        guard let point = MacScoreClickMapping.stripDocumentPoint(
            hostedPoint: hostedPoint,
            contentInset: MacHorizontalMetrics.contentInset,
            documentSize: document.size,
        ) else {
            readerLogClick("strip hosted=\(hostedPoint) -> outside the engraving")
            if let host = editingHost, host.isEditing {
                host.onTapOutsideScore()
            }
            return
        }
        guard !isUnderStickyPane(documentX: point.x, document: document) else {
            readerLogClick("strip doc=\(point) -> under the sticky pane, rejected")
            return
        }
        if let host = editingHost, host.wantsScoreTaps {
            readerLogClick("strip doc=\(point) -> editing onTap")
            host.onTap(point)
            return
        }
        guard let cursor = nearestCursor(at: point, in: document) else {
            readerLogClick("strip doc=\(point) -> no cursor")
            return
        }
        readerLogClick("strip doc=\(point) -> \(cursor)")
        viewModel.playbackSession.setManualCursor(cursor)
        editingHost?.rememberTappedItem(cursor)
    }

    /// Whether `documentX` is hidden behind the sticky pane at the current scroll offset. False whenever the pane is
    /// not on screen, which is every scroll position before the score's own bracket reaches the leading edge.
    private func isUnderStickyPane(documentX: CGFloat, document: LayoutDocument) -> Bool {
        guard !state.measureContexts.isEmpty else { return false }
        let geometry = MacStickyPaneGeometry(document: document, scrollX: viewportState.scroll.x)
        guard geometry.isVisible else { return false }
        return documentX < document.stickyTrailingX(
            scoreScrollX: geometry.scoreScrollX,
            measureContexts: state.measureContexts,
        )
    }
}
#endif

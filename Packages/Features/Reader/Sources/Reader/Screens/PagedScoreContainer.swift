import CoreGraphics
import SheetMusicLayout
import SwiftUI

/// Page-by-page Reader mode. Lays the score out at viewport width (same
/// as `VerticalScoreContainer`), paginates the resulting systems by
/// viewport height, and shows one page at a time. The full `ScoreView`
/// is drawn behind a `.clipped()` band so tap-seek / playback cursor /
/// AB-loop overlays continue to operate in full-document coordinates.
struct PagedScoreContainer: View {
    var body: some View {
        // Placeholder body — populated in Task 3.
        Color.clear
    }

    /// Greedy paginator: walks systems in order, packs them onto the
    /// current page until the next one would overflow `pageHeight`,
    /// then starts a new page. Authored `<LayoutBreak>page` markup on
    /// the last measure of a system closes the page immediately under
    /// `.honor` / `.ignoreSystemBreaks`. Under `.ignoreAll` page breaks
    /// are ignored and pages only close on vertical overflow.
    ///
    /// Mirrors `SheetMusicUI.PagedScoreView.paginate` — that helper is
    /// `internal` to `SheetMusicUI` and not reachable from a consumer,
    /// so we re-implement the ~30 lines here instead of widening the
    /// sheet-music API surface.
    static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [Range<Int>] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        var pages: [Range<Int>] = []
        var pageStart = 0
        var usedHeight: CGFloat = 0

        for (index, system) in systems.enumerated() {
            let h = system.size.height
            if index > pageStart, usedHeight + h > pageHeight {
                pages.append(pageStart ..< index)
                pageStart = index
                usedHeight = 0
            }
            usedHeight += h

            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
                pages.append(pageStart ..< (index + 1))
                pageStart = index + 1
                usedHeight = 0
            }
        }
        if pageStart < systems.count {
            pages.append(pageStart ..< systems.count)
        }
        return pages
    }
}

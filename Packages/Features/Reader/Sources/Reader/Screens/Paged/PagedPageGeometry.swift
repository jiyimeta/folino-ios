import CoreGraphics
import SheetMusicLayout

/// Page-band vertical bounds in full-document layout coordinates, shared by `PagedZoomedSurface` (clip/offset) and
/// `PagedScoreContainer` (annotation projection + per-page partition). One definition so the band the score is clipped
/// to and the band annotations are projected into can never drift.
enum PagedPageGeometry {
    /// First page renders from doc-Y `0` (title frame visible); every later page starts at the previous page's
    /// last-system bottom (so the gap above its own first system — rehearsal marks — lands on the right page).
    static func pageStartY(forPage index: Int, pages: [Range<Int>], doc: LayoutDocument) -> CGFloat {
        guard index > 0, pages.indices.contains(index - 1) else { return 0 }
        let prevLastIndex = pages[index - 1].upperBound - 1
        guard doc.systems.indices.contains(prevLastIndex) else { return 0 }
        return doc.systems[prevLastIndex].origin.y + doc.systems[prevLastIndex].size.height
    }

    /// Bottom of this page's last system (so anchors below the last system still resolve to this page). Falls back to
    /// the page start for an empty/out-of-range page.
    static func pageEndY(forPage index: Int, pages: [Range<Int>], doc: LayoutDocument) -> CGFloat {
        guard pages.indices.contains(index) else { return pageStartY(forPage: index, pages: pages, doc: doc) }
        let lastSystemIndex = pages[index].upperBound - 1
        guard doc.systems.indices.contains(lastSystemIndex) else {
            return pageStartY(forPage: index, pages: pages, doc: doc)
        }
        return doc.systems[lastSystemIndex].origin.y + doc.systems[lastSystemIndex].size.height
    }
}

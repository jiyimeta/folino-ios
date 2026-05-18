import CoreGraphics
@testable import Reader
import SheetMusicLayout
import Testing

struct PagedScoreContainerPaginateTests {
    /// Builds a `LayoutSystem` placed at `originY` in document coordinates with the requested height. Other fields are
    /// stubbed to the minimum init can swallow — pagination math only inspects `origin.y`, `size.height`, and
    /// `measures.last?.pageBreak`.
    ///
    /// The real `LayoutEngine` bakes `systemGap` into `origin.y`, so callers expressing a gap should leave a numeric
    /// gap between successive `originY` values rather than passing it separately.
    private static func system(
        originY: CGFloat,
        height: CGFloat,
        endsWithPageBreak: Bool = false,
    ) -> LayoutSystem {
        let measure = LayoutMeasure(
            measureIndex: 0,
            origin: .zero,
            width: 100,
            elements: [],
            pageBreak: endsWithPageBreak,
        )
        return LayoutSystem(
            origin: CGPoint(x: 0, y: originY),
            size: CGSize(width: 100, height: height),
            measures: [measure],
            staffOrigins: [.zero],
            partLabels: [],
            spanners: [],
            sp: 4,
        )
    }

    @Test func `empty systems yields empty pages`() {
        let pages = PagedScoreContainer.paginate(
            systems: [], pageHeight: 800, policy: .honor,
        )
        #expect(pages.isEmpty)
    }

    @Test func `zero page height yields empty pages defensively`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(originY: 0, height: 100)],
            pageHeight: 0, policy: .honor,
        )
        #expect(pages.isEmpty)
    }

    @Test func `single small system fits one page`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(originY: 0, height: 100)],
            pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1])
    }

    @Test func `two systems that both fit go on one page`() {
        let systems = [
            Self.system(originY: 0, height: 200),
            Self.system(originY: 220, height: 300), // 20 pt gap
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 2])
    }

    @Test func `second system overflows and starts a new page`() {
        let systems = [
            Self.system(originY: 0, height: 500),
            Self.system(originY: 520, height: 400), // bottom = 920 > 800
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 2])
    }

    /// Two systems whose `size.height` sum (= 800) fits the page, but whose combined extent including `systemGap`
    /// exceeds it. The old size-only paginator put both on one page; the new origin-based paginator correctly splits
    /// them.
    @Test func `system gap counts toward page extent`() {
        let systems = [
            Self.system(originY: 0, height: 400),
            Self.system(originY: 420, height: 400), // bottom = 820 > 800
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 2])
    }

    @Test func `authored pageBreak closes the page under honor`() {
        let systems = [
            Self.system(originY: 0, height: 200, endsWithPageBreak: true),
            Self.system(originY: 220, height: 200),
            Self.system(originY: 440, height: 200),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 3])
    }

    @Test func `authored pageBreak is ignored under ignoreAll`() {
        let systems = [
            Self.system(originY: 0, height: 200, endsWithPageBreak: true),
            Self.system(originY: 220, height: 200),
            Self.system(originY: 440, height: 200),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .ignoreAll,
        )
        // All three fit vertically (bottom of last = 640 < 800); without the page-break closing page 1 they share a
        // single page.
        #expect(pages == [0 ..< 3])
    }

    @Test func `system taller than page emits a single-system page`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(originY: 0, height: 1200)],
            pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1])
    }
}

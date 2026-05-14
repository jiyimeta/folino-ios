import CoreGraphics
@testable import Reader
import SheetMusicLayout
import Testing

struct PagedScoreContainerPaginateTests {
    /// Builds a `LayoutSystem` with the requested height. Other fields
    /// are stubbed to the minimum init can swallow — pagination math
    /// only inspects `size.height` and `measures.last?.pageBreak`.
    private static func system(
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
            origin: .zero,
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
            systems: [Self.system(height: 100)],
            pageHeight: 0, policy: .honor,
        )
        #expect(pages.isEmpty)
    }

    @Test func `single small system fits one page`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(height: 100)],
            pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1])
    }

    @Test func `two systems that both fit go on one page`() {
        let systems = [
            Self.system(height: 200),
            Self.system(height: 300),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 2])
    }

    @Test func `second system overflows and starts a new page`() {
        let systems = [
            Self.system(height: 500),
            Self.system(height: 400),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 2])
    }

    @Test func `authored pageBreak closes the page under honor`() {
        let systems = [
            Self.system(height: 200, endsWithPageBreak: true),
            Self.system(height: 200),
            Self.system(height: 200),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1, 1 ..< 3])
    }

    @Test func `authored pageBreak is ignored under ignoreAll`() {
        let systems = [
            Self.system(height: 200, endsWithPageBreak: true),
            Self.system(height: 200),
            Self.system(height: 200),
        ]
        let pages = PagedScoreContainer.paginate(
            systems: systems, pageHeight: 800, policy: .ignoreAll,
        )
        #expect(pages == [0 ..< 3])
    }

    @Test func `system taller than page emits a single-system page`() {
        let pages = PagedScoreContainer.paginate(
            systems: [Self.system(height: 1200)],
            pageHeight: 800, policy: .honor,
        )
        #expect(pages == [0 ..< 1])
    }
}

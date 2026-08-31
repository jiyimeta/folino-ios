import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("AnnotatedExportPlanner")
struct AnnotatedExportPlannerTests {
    /// Resolver that reports a fixed reference point per measure index and a fixed `sp`, so the tests can place an
    /// anchor at a chosen document Y without building a real layout.
    private struct StubResolver: AnchorResolving {
        var pointsByMeasure: [Int: CGPoint]
        var sp: CGFloat = 10

        func resolveAnchor(at point: CGPoint) -> MusicalAnchor? {
            nil
        }

        func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? {
            guard let point = pointsByMeasure[anchor.measureIndex] else { return nil }
            return (point, sp)
        }
    }

    private static func musical(measure: Int) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: measure, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                dxSp: 0, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data(),
        )
    }

    private static func page(_ index: Int) -> DrawingAnchor {
        DrawingAnchor(kind: .page(PageAnchor(pageIndex: index)), encodedDrawing: Data())
    }

    private static let twoPages = [
        EngravedPagePlacement(startY: 0, usableHeight: 700, offsetX: 50, offsetY: 60),
        EngravedPagePlacement(startY: 700, usableHeight: 700, offsetX: 50, offsetY: 60 - 700),
    ]

    @Test
    func `a stroke lands on the page whose band holds its anchor, offset into page space`() throws {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 100, y: 200)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0)], resolver: resolver, pages: Self.twoPages,
        )
        #expect(placements.count == 1)
        let placement = try #require(placements.first)
        #expect(placement.pageIndex == 0)
        #expect(placement.drawingIndex == 0)
        #expect(placement.transform.sp == 10)
        #expect(placement.transform.px == 150) // 100 + offsetX
        #expect(placement.transform.py == 260) // 200 + offsetY
    }

    @Test
    func `a stroke past the first band lands on the second page`() throws {
        let resolver = StubResolver(pointsByMeasure: [3: CGPoint(x: 100, y: 900)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 3)], resolver: resolver, pages: Self.twoPages,
        )
        let placement = try #require(placements.first)
        #expect(placement.pageIndex == 1)
        #expect(placement.transform.px == 150)
        #expect(placement.transform.py == 260) // 900 + (60 - 700)
    }

    @Test
    func `an anchor the layout cannot resolve is dropped, not mis-placed`() {
        let resolver = StubResolver(pointsByMeasure: [:])
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 7)], resolver: resolver, pages: Self.twoPages,
        ).isEmpty)
    }

    @Test
    func `an anchor beyond the last page's band is dropped`() {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 0, y: 5000)])
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0)], resolver: resolver, pages: Self.twoPages,
        ).isEmpty)
    }

    /// Regression for the device QA bug: a mark drawn above the top staff of page 1 resolves to a negative document
    /// Y (headroom above `startY == 0`), which used to satisfy no page's band and silently produced zero placements.
    @Test
    func `an anchor above page 1's band still lands on page 1, not nowhere`() throws {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 100, y: -30)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0)], resolver: resolver, pages: Self.twoPages,
        )
        let placement = try #require(placements.first)
        #expect(placement.pageIndex == 0)
        #expect(placement.transform.px == 150) // 100 + offsetX
        #expect(placement.transform.py == 30) // -30 + offsetY (60)
    }

    @Test
    func `drawingIndex points back into the input array when some drawings are dropped`() {
        let resolver = StubResolver(pointsByMeasure: [1: CGPoint(x: 10, y: 20)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0), Self.musical(measure: 1)],
            resolver: resolver, pages: Self.twoPages,
        )
        #expect(placements.map(\.drawingIndex) == [1])
    }

    @Test
    func `a page anchor is placed by page width so a differently sized page still fits it`() {
        let frames = [
            CGRect(x: 0, y: 0, width: 400, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: 1200),
        ]
        let placements = AnnotatedExportPlanner.planPaged(
            drawings: [Self.page(0), Self.page(1)], pageFrames: frames,
        )
        #expect(placements.map(\.pageIndex) == [0, 1])
        #expect(placements[0].transform.sp == 400)
        #expect(placements[1].transform.sp == 800)
    }

    @Test
    func `a page anchor beyond the document's pages is dropped`() {
        let frames = [CGRect(x: 0, y: 0, width: 400, height: 600)]
        #expect(AnnotatedExportPlanner.planPaged(drawings: [Self.page(4)], pageFrames: frames).isEmpty)
    }

    @Test
    func `each planner ignores the other planner's anchor kind`() {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 0, y: 10)])
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [Self.page(0)], resolver: resolver, pages: Self.twoPages,
        ).isEmpty)
        #expect(AnnotatedExportPlanner.planPaged(
            drawings: [Self.musical(measure: 0)],
            pageFrames: [CGRect(x: 0, y: 0, width: 400, height: 600)],
        ).isEmpty)
    }

    @Test
    func `empty inputs produce no placements`() {
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [], resolver: StubResolver(pointsByMeasure: [:]), pages: Self.twoPages,
        ).isEmpty)
        #expect(AnnotatedExportPlanner.planPaged(drawings: [Self.page(0)], pageFrames: []).isEmpty)
    }
}

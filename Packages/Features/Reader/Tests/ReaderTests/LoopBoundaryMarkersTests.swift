import CoreGraphics
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import Testing

@Suite struct LoopBoundaryMarkersTests {
    private static let sp: CGFloat = 14.0 / 4 // staffSize 14 → sp 3.5
    private static let triangleHeight: CGFloat = sp * LoopBoundaryMarkers.triangleHeightFactor
    private static let triangleWidth: CGFloat = sp * LoopBoundaryMarkers.triangleWidthFactor
    private static let lineThickness: CGFloat = sp * LoopBoundaryMarkers.lineThicknessFactor

    /// One system at y=100, height=60, with two measures:
    /// measure 0 origin.x = 0, width 80; measure 1 origin.x = 80, width 100.
    private static func makeDocument() -> LayoutDocument {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let m0 = LayoutMeasure(measureIndex: 0, origin: .zero, width: 80, elements: [])
        let m1 = LayoutMeasure(
            measureIndex: 1,
            origin: CGPoint(x: 80, y: 0),
            width: 100,
            elements: []
        )
        let system = LayoutSystem(
            origin: CGPoint(x: 10, y: 100),
            size: CGSize(width: 180, height: 60),
            measures: [m0, m1],
            staffOrigins: [.zero],
            staffAddresses: [staff],
            partLabels: [], spanners: [], sp: sp
        )
        let metrics = StaffMetrics(staffSize: 14)
        return LayoutDocument(
            size: CGSize(width: 200, height: 200),
            systems: [system],
            metrics: metrics
        )
    }

    @Test func aMarkerLineSitsAtMeasureLeftEdge() throws {
        let doc = Self.makeDocument()
        let result = aMarkerGeometry(
            document: doc, measureIndex: 0,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let line = try #require(result?.line)
        // Measure 0: system.origin.x (10) + measure.origin.x (0) = 10.
        // Line is centered on that x, so origin.x = 10 - thickness/2.
        #expect(line.origin.x == 10 - Self.lineThickness / 2)
        // Y span: systemTop − triangleHeight (100 − 1*sp) to systemBottom (160).
        #expect(line.origin.y == 100 - Self.triangleHeight)
        #expect(line.size.height == 60 + Self.triangleHeight)
        #expect(line.size.width == Self.lineThickness)
    }

    @Test func bMarkerLineSitsAtMeasureRightEdge() throws {
        let doc = Self.makeDocument()
        let result = bMarkerGeometry(
            document: doc, measureIndex: 1,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let line = try #require(result?.line)
        // Measure 1: system.origin.x (10) + measure.origin.x (80) + width (100) = 190.
        #expect(line.origin.x == 190 - Self.lineThickness / 2)
        #expect(line.origin.y == 100 - Self.triangleHeight)
        #expect(line.size.height == 60 + Self.triangleHeight)
        #expect(line.size.width == Self.lineThickness)
    }

    @Test func aMarkerTrianglePointsRight() throws {
        let doc = Self.makeDocument()
        let result = aMarkerGeometry(
            document: doc, measureIndex: 0,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let bbox = try #require(result?.triangle.boundingRect)
        // Apex (max X) is to the right of the line center (x = 10).
        // Use a tolerance because CGFloat bbox arithmetic can drift by ~2e-7.
        #expect(abs(bbox.maxX - (10 + Self.triangleWidth)) < 1e-4)
        #expect(bbox.minX == 10) // flat side aligned with line
        // Triangle sits above the system (top of system = 100).
        #expect(bbox.maxY <= 100)
        #expect(bbox.minY == 100 - Self.triangleHeight)
    }

    @Test func bMarkerTrianglePointsLeft() throws {
        let doc = Self.makeDocument()
        let result = bMarkerGeometry(
            document: doc, measureIndex: 1,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let bbox = try #require(result?.triangle.boundingRect)
        // Line center for measure 1 right edge = 190; apex (min X) is to its left.
        // Use a tolerance because CGFloat bbox arithmetic can drift by ~2e-7.
        #expect(abs(bbox.minX - (190 - Self.triangleWidth)) < 1e-4)
        #expect(bbox.maxX == 190) // flat side aligned with line
        #expect(bbox.minY == 100 - Self.triangleHeight)
    }

    @Test func returnsNilWhenMeasureMissing() {
        let doc = Self.makeDocument()
        #expect(aMarkerGeometry(
            document: doc, measureIndex: 99,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        ) == nil)
        #expect(bMarkerGeometry(
            document: doc, measureIndex: 99,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        ) == nil)
    }
}

import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

struct PageAnchoringCoreTests {
    private let frames = [
        CGRect(x: 0, y: 0, width: 100, height: 200),
        CGRect(x: 0, y: 220, width: 100, height: 200),
    ]

    @Test func `centroid inside A page resolves to that page`() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 100), pageFrames: frames) == 0)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 300), pageFrames: frames) == 1)
    }

    /// A stroke landing in the gap belongs to the nearest page; an exact tie resolves upward.
    @Test func `centroid in the gap resolves to the nearer page`() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 205), pageFrames: frames) == 0)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 215), pageFrames: frames) == 1)
        #expect(PageAnchoringCore.pageIndex(forCentroid: CGPoint(x: 50, y: 210), pageFrames: frames) == 0)
    }

    @Test func `no pages means no anchor`() {
        #expect(PageAnchoringCore.pageIndex(forCentroid: .zero, pageFrames: []) == nil)
    }

    /// Normalization is a fraction of PAGE WIDTH in both axes, so zoom cancels out.
    @Test func `normalize and display are inverses`() throws {
        let frame = CGRect(x: 10, y: 220, width: 100, height: 200)
        let normalize = try #require(PageAnchoringCore.normalizeTransform(pageFrame: frame))
        let display = try #require(PageAnchoringCore.displayTransform(pageFrame: frame))
        let point = CGPoint(x: 60, y: 320)
        let round = point.applying(normalize).applying(display)
        #expect(abs(round.x - point.x) < 0.0001)
        #expect(abs(round.y - point.y) < 0.0001)
    }

    @Test func `zero width page has no transform`() {
        #expect(PageAnchoringCore.normalizeTransform(pageFrame: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
    }

    @Test func `partition keeps off page drawings`() {
        let onPage = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data([1]))
        let elsewhere = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data([2]))
        let split = PageAnchoringCore.partitionByPage([onPage, elsewhere], pageIndex: 1)
        #expect(split.onPage.count == 1)
        #expect(split.offPage.count == 1)
    }

    @Test func `display transforms are nil for other pages`() {
        let drawing = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 5)), encodedDrawing: Data([1]))
        #expect(PageAnchoringCore.displayTransforms([drawing], pageFrames: frames) == [nil])
    }
}

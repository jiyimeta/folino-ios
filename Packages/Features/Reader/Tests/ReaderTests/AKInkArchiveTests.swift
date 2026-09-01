import CoreGraphics
import Foundation
@testable import Reader
@testable import ReaderAnnotationCore
import Testing

@Suite("AK ink archive")
struct AKInkArchiveTests {
    private func plist(_ data: Data) throws -> [String: Any] {
        try #require(try PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test
    func `it is a keyed archive of AKInkAnnotation2`() throws {
        let data = try AKInkArchive.archive(
            payload: Data([1, 2, 3]), archiveRect: CGRect(x: 1, y: 2, width: 3, height: 4),
            drawingSize: CGSize(width: 100, height: 200), uuid: UUID(), deflater: AppleDeflater(),
        )
        let p = try plist(data)
        #expect(p["$archiver"] as? String == "NSKeyedArchiver")
        let objects = try #require(p["$objects"] as? [Any])
        let names = objects.compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        #expect(names.contains("AKInkAnnotation2"))
    }

    @Test
    func `the rectangle round-trips through the archive`() throws {
        let rect = CGRect(
            x: 145.60262044270834, y: 497.5652598896043,
            width: 228.1608072916667, height: 8.254427322907077,
        )
        let data = try AKInkArchive.archive(
            payload: Data([1, 2, 3]), archiveRect: rect,
            drawingSize: CGSize(width: 792.7741935483871, height: 1122.0645161290322),
            uuid: UUID(), deflater: AppleDeflater(),
        )
        let objects = try #require(try plist(data)["$objects"] as? [Any])
        let numbers = objects.compactMap { $0 as? Double }
        // Full precision matters: a tenth of a point of drift is enough for the annotation to be discarded.
        #expect(numbers.contains { abs($0 - rect.origin.x) < 1e-12 })
        #expect(numbers.contains { abs($0 - rect.origin.y) < 1e-12 })
        #expect(numbers.contains { abs($0 - rect.width) < 1e-12 })
        #expect(numbers.contains { abs($0 - rect.height) < 1e-12 })
    }

    @Test
    func `the drawing is stored gzipped`() throws {
        let data = try AKInkArchive.archive(
            payload: Data(repeating: 7, count: 400), archiveRect: .zero,
            drawingSize: CGSize(width: 100, height: 200), uuid: UUID(), deflater: AppleDeflater(),
        )
        let objects = try #require(try plist(data)["$objects"] as? [Any])
        let blobs = objects.compactMap { $0 as? Data }.filter { $0.prefix(3) == Data([0x1F, 0x8B, 0x08]) }
        #expect(blobs.count == 1)
    }
}

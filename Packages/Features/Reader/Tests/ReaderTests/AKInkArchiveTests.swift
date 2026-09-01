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

    /// `PropertyListSerialization` hands back a `CF$UID` reference as an opaque `CFKeyedArchiverUID`, which
    /// Swift only sees as `__NSCFType` — it is not an `NSNumber` and answers none of `intValue`/`longValue`/
    /// `value` to the runtime, so there is no typed accessor for the integer index it wraps. Its
    /// `-description` has printed `<CFKeyedArchiverUID ...>{value = N}` for as long as the type has existed,
    /// so this parses that rather than reaching for anything more exotic. Test-only: production code never
    /// inspects a UID this way.
    private func uidIndex(_ any: Any) throws -> Int {
        let text = String(describing: any)
        let afterMarker = try #require(text.range(of: "value = ")).upperBound
        let closeBrace = try #require(text.range(of: "}", range: afterMarker ..< text.endIndex))
        return try #require(Int(text[afterMarker ..< closeBrace.lowerBound]))
    }

    /// Resolves a `CF$UID` reference to the `$objects` entry it points at.
    private func resolved(_ objects: [Any], _ uid: Any) throws -> Any {
        let index = try uidIndex(uid)
        return try #require(objects.indices.contains(index) ? objects[index] : nil)
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
        let root = try plist(data)
        let objects = try #require(root["$objects"] as? [Any])

        // $top.root -> the archived object -> its "rectangle" key -> the NSMutableDictionary it references.
        let top = try #require(root["$top"] as? [String: Any])
        let rootUID = try #require(top["root"])
        let rootObject = try #require(try resolved(objects, rootUID) as? [String: Any])
        let rectangleUID = try #require(rootObject["rectangle"])
        let rectangle = try #require(try resolved(objects, rectangleUID) as? [String: Any])

        // An archived NSDictionary stores its contents as two parallel UID arrays rather than inline
        // key-value pairs, so each key and each value has to be resolved through $objects in turn.
        let keyUIDs = try #require(rectangle["NS.keys"] as? [Any])
        let valueUIDs = try #require(rectangle["NS.objects"] as? [Any])
        var values: [String: Double] = [:]
        for (keyUID, valueUID) in zip(keyUIDs, valueUIDs) {
            let key = try #require(try resolved(objects, keyUID) as? String)
            values[key] = try #require(try resolved(objects, valueUID) as? Double)
        }

        // Full precision matters: a tenth of a point of drift is enough for the annotation to be discarded.
        // Checked against the right key, not just present somewhere in the archive — a swapped X/Y would
        // pass a flat membership check but produce exactly the silent, undetected failure this format
        // punishes.
        #expect(try abs(#require(values["X"]) - rect.origin.x) < 1e-12)
        #expect(try abs(#require(values["Y"]) - rect.origin.y) < 1e-12)
        #expect(try abs(#require(values["Width"]) - rect.width) < 1e-12)
        #expect(try abs(#require(values["Height"]) - rect.height) < 1e-12)
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

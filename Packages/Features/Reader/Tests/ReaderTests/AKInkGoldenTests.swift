import Compression
import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("AK ink structural golden")
struct AKInkGoldenTests {
    private enum GoldenTestError: Error { case noInkBox }

    /// (field number, wire type) in order, at one nesting level.
    private func shape(_ data: Data) -> [(Int, UInt64)] {
        var out: [(Int, UInt64)] = []
        var i = data.startIndex
        while i < data.endIndex {
            var tag: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                tag |= UInt64(b & 0x7F) << shift
                shift += 7
                if b & 0x80 == 0 {
                    break
                }
            }
            let field = Int(tag >> 3), wire = tag & 7
            out.append((field, wire))
            switch wire {
            case 0:
                while i < data.endIndex, data[i] & 0x80 != 0 {
                    i += 1
                }
                i += 1
            case 1: i += 8
            case 5: i += 4
            case 2:
                var length: UInt64 = 0, lshift: UInt64 = 0
                while i < data.endIndex {
                    let b = data[i]; i += 1
                    length |= UInt64(b & 0x7F) << lshift
                    lshift += 7
                    if b & 0x80 == 0 {
                        break
                    }
                }
                i += Int(length)
            default: return out
            }
        }
        return out
    }

    private func ours() throws -> Data {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: 2, opacity: 1,
            x: [10, 30, 50], y: [20, 40, 20], width: [2, 2, 2],
            force: [], azimuth: [], altitude: [], timeMillis: [],
        )
        guard let box = AKInkGeometry.inkBox(of: [stroke]) else { throw GoldenTestError.noInkBox }
        return AKInkPayloadEncoder.payload(
            for: stroke, inkBox: box,
            identifiers: (0 ..< 5).map { Data(repeating: UInt8($0 + 1), count: 16) },
            timestamp: 810_000_000,
        )
    }

    @Test
    func `our payload has Apple's field order and wire types at every level`() throws {
        let url = try #require(Bundle.module.url(forResource: "apple-ink-sample", withExtension: "bin"))
        let apple = try AKTestSupport.drawingPayload(inArchiveAt: url)
        let ourPayload = try ours()

        #expect(shape(ourPayload).map(\.0) == shape(apple).map(\.0))
        #expect(shape(ourPayload).map(\.1) == shape(apple).map(\.1))

        for level in [2] {
            let a = try #require(ProtobufReaderStub.field(level, in: apple))
            let b = try #require(ProtobufReaderStub.field(level, in: ourPayload))
            #expect(shape(b).map(\.0) == shape(a).map(\.0))
            #expect(shape(b).map(\.1) == shape(a).map(\.1))
        }

        let appleDrawing = try #require(ProtobufReaderStub.field(2, in: apple))
        let appleStroke = try #require(ProtobufReaderStub.field(3, in: appleDrawing))
        let ourDrawing = try #require(ProtobufReaderStub.field(2, in: ourPayload))
        let ourStroke = try #require(ProtobufReaderStub.field(3, in: ourDrawing))
        // `.2` and `.3` each occur twice on the stroke. Emitting one of a repeated field is exactly the defect
        // this comparison exists to catch, so the counts are part of the assertion.
        #expect(shape(ourStroke).map(\.0) == shape(appleStroke).map(\.0))
        #expect(shape(ourStroke).map(\.1) == shape(appleStroke).map(\.1))

        let applePoints = try #require(ProtobufReaderStub.field(5, in: appleStroke))
        let ourPoints = try #require(ProtobufReaderStub.field(5, in: ourStroke))
        #expect(shape(ourPoints).map(\.0) == shape(applePoints).map(\.0))
        #expect(shape(ourPoints).map(\.1) == shape(applePoints).map(\.1))

        // Field 4 on the stroke is the ink submessage (colour, tool identifier, and one unexplained varint).
        // It's only checked as one length-delimited blob at the stroke level above; this descends one level
        // further so a wire-type flip inside it — exactly the kind of defect this file exists to catch —
        // doesn't hide behind "it's still a valid length-delimited field."
        let appleInk = try #require(ProtobufReaderStub.field(4, in: appleStroke))
        let ourInk = try #require(ProtobufReaderStub.field(4, in: ourStroke))
        #expect(shape(ourInk).map(\.0) == shape(appleInk).map(\.0))
        #expect(shape(ourInk).map(\.1) == shape(appleInk).map(\.1))
    }

    @Test
    func `our point records are the same length as Apple's`() throws {
        let url = try #require(Bundle.module.url(forResource: "apple-ink-sample", withExtension: "bin"))
        let apple = try AKTestSupport.drawingPayload(inArchiveAt: url)
        for payload in try [apple, ours()] {
            let drawing = try #require(ProtobufReaderStub.field(2, in: payload))
            let stroke = try #require(ProtobufReaderStub.field(3, in: drawing))
            let points = try #require(ProtobufReaderStub.field(5, in: stroke))
            let blob = try #require(ProtobufReaderStub.field(5, in: points))
            #expect(blob.count % 24 == 0)
        }
    }
}

/// Pulls the gzipped drawing back out of a real Apple archive, for tests only.
enum AKTestSupport {
    enum SupportError: Error { case noDrawingInArchive }

    /// `#require` belongs inside a test; this is a plain throwing helper, so it throws its own error instead.
    static func drawingPayload(inArchiveAt url: URL) throws -> Data {
        let plist = try PropertyListSerialization
            .propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        let objects = (plist?["$objects"] as? [Any]) ?? []
        guard let gzip = objects.compactMap({ $0 as? Data })
            .first(where: { $0.prefix(3) == Data([0x1F, 0x8B, 0x08]) })
        else { throw SupportError.noDrawingInArchive }
        return try gunzip(gzip)
    }

    /// Strips the gzip framing and inflates the raw DEFLATE body.
    private static func gunzip(_ data: Data) throws -> Data {
        let body = data.dropFirst(10).dropLast(8)
        let size = data.suffix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        var out = Data(count: Int(size))
        let produced = out.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return Data(body).withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, Int(size), srcBase, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(produced)
    }
}

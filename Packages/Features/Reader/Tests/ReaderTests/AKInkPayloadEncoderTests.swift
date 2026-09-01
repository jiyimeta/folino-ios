import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("AK ink payload encoder")
struct AKInkPayloadEncoderTests {
    private let ids = (0 ..< 5).map { Data(repeating: UInt8($0 + 1), count: 16) }

    private func stroke(
        width: [Float] = [2, 2], force: [Float] = [], time: [UInt16] = [], baseWidthSp: Float = 2,
    ) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: baseWidthSp, opacity: 1,
            x: [10, 30], y: [20, 40], width: width, force: force, azimuth: [], altitude: [], timeMillis: time,
        )
    }

    /// The stroke message: field 3 of the drawing, which is field 2 of the payload.
    private func drawingStroke(_ payload: Data) throws -> Data {
        let drawing = try #require(ProtobufReaderStub.field(2, in: payload))
        return try #require(ProtobufReaderStub.field(3, in: drawing))
    }

    /// The points container: field 5 of the stroke.
    private func points(_ payload: Data) throws -> Data {
        try #require(try ProtobufReaderStub.field(5, in: drawingStroke(payload)))
    }

    /// The 24-byte point records: field 5 of the points container.
    private func records(_ payload: Data) throws -> [Data] {
        let blob = try #require(try ProtobufReaderStub.field(5, in: points(payload)))
        return stride(from: 0, to: blob.count, by: 24).map { blob[$0 ..< $0 + 24] }.map { Data($0) }
    }

    @Test
    func `a point record carries the trailing constants in Apple's byte order`() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let first = try #require(records(payload).first)
        #expect(first[14 ..< 16] == Data([0xE8, 0x03])) // 1000
        #expect(first[16 ..< 18] == Data([0x00, 0x00])) // 0
        #expect(first[20 ..< 22] == Data([0xAA, 0xAA])) // 0xAAAA
        #expect(first[22 ..< 24] == Data([0x54, 0xFE])) // 0xFE54, little-endian
    }

    @Test
    func `width is a tenth of a canvas unit, so a two-point pen reads about twenty-seven`() throws {
        // Apple's thin pen measures 24-26 and its thickest 40-56 on a canvas scaled 96/72 from the page.
        // baseWidthSp is deliberately different from width so an implementation that fell back to baseWidthSp
        // instead of reading the per-point array would fail this assertion.
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(width: [2, 2], baseWidthSp: 9), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let first = try #require(records(payload).first)
        let width = first[12 ..< 14].withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
        #expect(width == 27)
    }

    @Test
    func `a stroke with no captured time gets an eight-millisecond cadence`() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(time: []), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let second = try records(payload)[1]
        let t = second[0 ..< 4].withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(as: UInt32.self)) }
        #expect(abs(t - 0.008) < 0.000_1)
    }

    @Test
    func `captured time in milliseconds converts to seconds`() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(time: [0, 250]), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let second = try records(payload)[1]
        let t = second[0 ..< 4].withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(as: UInt32.self)) }
        #expect(abs(t - 0.25) < 0.000_1)
    }

    @Test
    func `point coordinates land in canvas units, scaled from page points`() throws {
        // scale is 96/72; x: 10 -> 13.3333, y: 20 -> 26.6667. This is the one failure the format notes call
        // fatal and silent: if the points stayed in page points while the stored bounding box was scaled, the
        // two would no longer describe the same area, and the ink would render but never be erasable.
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let first = try #require(records(payload).first)
        let x = first[4 ..< 8].withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(as: UInt32.self)) }
        let y = first[8 ..< 12].withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(as: UInt32.self)) }
        #expect(abs(x - 13.3333) < 0.001)
        #expect(abs(y - 26.6667) < 0.001)
    }

    @Test
    func `stroke color channels are written R, G, B, A — not A, R, G, B`() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let ink = try #require(try ProtobufReaderStub.field(4, in: drawingStroke(payload)))
        let rgba = try #require(ProtobufReaderStub.field(1, in: ink))
        func channel(_ number: Int) throws -> Float {
            try Float(bitPattern: #require(ProtobufReaderStub.fixed32Field(number, in: rgba)))
        }
        #expect(try abs(channel(1) - 1.0) < 0.001)
        #expect(try abs(channel(2) - 0.2) < 0.001)
        #expect(try abs(channel(3) - 0.1333) < 0.001)
        #expect(try abs(channel(4) - 1.0) < 0.001)
    }

    @Test
    func `point count matches the records written`() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        let declared = try #require(try ProtobufReaderStub.varintField(4, in: points(payload)))
        let actual = try records(payload).count
        #expect(declared == UInt64(actual))
        #expect(actual == 2)
    }
}

/// A read-side helper for tests only.
enum ProtobufReaderStub {
    /// The first length-delimited (wire type 2) field with the given number.
    static func field(_ number: Int, in data: Data) -> Data? {
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
                let end = i + Int(length)
                if field == number {
                    return Data(data[i ..< end])
                }
                i = end
            default: return nil
            }
        }
        return nil
    }

    /// The first varint (wire type 0) field with the given number, as its raw unsigned value.
    static func varintField(_ number: Int, in data: Data) -> UInt64? {
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
            switch wire {
            case 0:
                var value: UInt64 = 0, vshift: UInt64 = 0
                while i < data.endIndex {
                    let b = data[i]; i += 1
                    value |= UInt64(b & 0x7F) << vshift
                    vshift += 7
                    if b & 0x80 == 0 {
                        break
                    }
                }
                if field == number {
                    return value
                }
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
            default: return nil
            }
        }
        return nil
    }

    /// The first fixed32 (wire type 5) field with the given number, as its raw bit pattern.
    static func fixed32Field(_ number: Int, in data: Data) -> UInt32? {
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
            switch wire {
            case 0:
                while i < data.endIndex, data[i] & 0x80 != 0 {
                    i += 1
                }
                i += 1
            case 1: i += 8
            case 5:
                guard i + 4 <= data.endIndex else { return nil }
                let value = data[i ..< i + 4].withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
                }
                i += 4
                if field == number {
                    return value
                }
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
            default: return nil
            }
        }
        return nil
    }
}

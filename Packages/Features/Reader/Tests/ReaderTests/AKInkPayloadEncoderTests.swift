import CoreGraphics
import Domain
import Foundation
@testable import ReaderAnnotationCore
import Testing

@Suite("AK ink payload encoder")
struct AKInkPayloadEncoderTests {
    private let ids = (0 ..< 5).map { Data(repeating: UInt8($0 + 1), count: 16) }

    private func stroke(width: [Float] = [2, 2], force: [Float] = [], time: [UInt16] = []) -> InkStroke {
        InkStroke(
            tool: .pen, colorRGBA: 0xFF33_22FF, baseWidthSp: 2, opacity: 1,
            x: [10, 30], y: [20, 40], width: width, force: force, azimuth: [], altitude: [], timeMillis: time,
        )
    }

    /// The 24-byte records live in field 5 of the points container, which is field 5 of the stroke, which is
    /// field 3 of the drawing, which is field 2 of the payload.
    private func records(_ payload: Data) throws -> [Data] {
        let drawing = try #require(ProtobufReaderStub.field(2, in: payload))
        let strokeBody = try #require(ProtobufReaderStub.field(3, in: drawing))
        let points = try #require(ProtobufReaderStub.field(5, in: strokeBody))
        let blob = try #require(ProtobufReaderStub.field(5, in: points))
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
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(width: [2, 2]), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
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
    func `point count matches the records written`() throws {
        let payload = AKInkPayloadEncoder.payload(
            for: stroke(), inkBox: CGRect(x: 0, y: 0, width: 40, height: 50),
            identifiers: ids, timestamp: 810_000_000,
        )
        #expect(try records(payload).count == 2)
    }
}

/// A read-side helper for tests only: returns the first length-delimited field with the given number.
enum ProtobufReaderStub {
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
}

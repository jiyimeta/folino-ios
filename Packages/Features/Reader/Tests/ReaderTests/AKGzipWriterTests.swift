import Compression
import Foundation
@testable import Reader
@testable import ReaderAnnotationCore
import Testing

@Suite("Gzip writer")
struct AKGzipWriterTests {
    /// Raw DEFLATE, so the test inflates the body itself rather than trusting a round trip through our own code.
    private func inflate(_ data: Data, into capacity: Int) -> Data {
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                // The test only ever inflates non-empty gzip bodies, so `baseAddress` is never nil here.
                // swiftlint:disable force_unwrapping
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB,
                )
                // swiftlint:enable force_unwrapping
            }
        }
        return out.prefix(produced)
    }

    @Test
    func `the header is a gzip header with deflate and no extras`() throws {
        let out = try GzipWriter.gzip(Data([1, 2, 3]), using: AppleDeflater())
        #expect(out.prefix(4) == Data([0x1F, 0x8B, 0x08, 0x00]))
    }

    @Test
    func `the body inflates back to the input and the trailer agrees`() throws {
        let payload = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let out = try GzipWriter.gzip(payload, using: AppleDeflater())

        let body = out.dropFirst(10).dropLast(8)
        #expect(inflate(Data(body), into: payload.count * 2) == payload)

        let trailer = out.suffix(8)
        let crc = trailer.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        #expect(crc == GzipWriter.crc32(payload))
        let isize = trailer.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: isize) == UInt32(payload.count))
    }

    @Test
    func `the CRC32 is the standard one`() {
        // "123456789" has a well-known CRC32 of 0xCBF43926.
        #expect(GzipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

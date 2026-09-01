import Compression
import Foundation
import ReaderAnnotationCore

/// `Deflating` over Apple's `Compression` framework.
///
/// `COMPRESSION_ZLIB` is misnamed: it produces RAW DEFLATE, with no zlib header or Adler checksum, which is
/// exactly what a gzip container wants. Wrapping its output in a zlib header would be the bug.
struct AppleDeflater: Deflating {
    func deflate(_ data: Data) throws -> Data {
        // Deflate can expand incompressible input; the allowance covers the worst case for payloads this size.
        let capacity = data.count + data.count / 2 + 128
        var out = Data(count: capacity)
        let produced = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                // `Compression` has no failable-buffer variant; annotation payloads are never empty in practice.
                // swiftlint:disable force_unwrapping
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB,
                )
                // swiftlint:enable force_unwrapping
            }
        }
        guard produced > 0 else { throw GzipWriter.GzipError.deflateFailed }
        return out.prefix(produced)
    }
}
